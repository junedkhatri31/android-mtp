#include "MTPBridge.h"
#include <libmtp.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>

struct AMConnection {
    LIBMTP_mtpdevice_t *device;
    char *name;
    char error[2048];
};
struct AMCancellation { atomic_bool cancelled; };
static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static void initialize(void) { LIBMTP_Init(); }

static void begin(AMConnection *c) {
    c->error[0] = '\0';
    LIBMTP_Clear_Errorstack(c->device);
}

static void capture_error(AMConnection *c, const char *fallback) {
    LIBMTP_error_t *e = LIBMTP_Get_Errorstack(c->device);
    size_t used = 0;
    for (; e && used < sizeof(c->error) - 1; e = e->next) {
        int length = snprintf(c->error + used, sizeof(c->error) - used, "%s%s",
                              used ? "\n" : "", e->error_text ? e->error_text : fallback);
        if (length > 0) used += (size_t)length < sizeof(c->error) - used
                                 ? (size_t)length : sizeof(c->error) - used - 1;
    }
    if (!used) snprintf(c->error, sizeof(c->error), "%s", fallback);
    LIBMTP_Clear_Errorstack(c->device);
}

int am_detect(AMDevice **devices, char *error, size_t capacity) {
    pthread_once(&initialization, initialize);
    *devices = NULL;
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&raw, &count);
    if (result == LIBMTP_ERROR_NO_DEVICE_ATTACHED) { free(raw); return 0; }
    if (result != LIBMTP_ERROR_NONE) {
        snprintf(error, capacity, "USB device discovery failed (libmtp error %d).", result);
        free(raw);
        return -1;
    }
    AMDevice **tail = devices;
    for (int i = 0; i < count; i++) {
        AMDevice *d = calloc(1, sizeof(*d));
        if (!d) { am_free_devices(*devices); *devices = NULL; free(raw); return -1; }
        d->bus = raw[i].bus_location;
        d->number = raw[i].devnum;
        const char *product = raw[i].device_entry.product;
        d->name = strdup(product ? product : "Android device");
        *tail = d;
        tail = &d->next;
    }
    free(raw);
    return 0;
}

void am_free_devices(AMDevice *d) {
    while (d) { AMDevice *next = d->next; free(d->name); free(d); d = next; }
}

AMConnection *am_open(uint32_t bus, uint8_t number, char *error, size_t capacity) {
    pthread_once(&initialization, initialize);
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_error_number_t status = LIBMTP_Detect_Raw_Devices(&raw, &count);
    if (status != LIBMTP_ERROR_NONE) {
        snprintf(error, capacity, "The device is no longer available. Reconnect it and try again.");
        free(raw);
        return NULL;
    }
    LIBMTP_mtpdevice_t *device = NULL;
    for (int i = 0; i < count; i++) {
        if (raw[i].bus_location == bus && raw[i].devnum == number) {
            device = LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
            break;
        }
    }
    free(raw);
    if (!device) {
        snprintf(error, capacity, "Could not open the device. Unlock your phone, choose File transfer / Android Auto for USB, and quit any other MTP apps.");
        return NULL;
    }
    AMConnection *c = calloc(1, sizeof(*c));
    if (!c) { LIBMTP_Release_Device(device); return NULL; }
    c->device = device;
    c->name = LIBMTP_Get_Friendlyname(device);
    if (!c->name || !*c->name) { free(c->name); c->name = LIBMTP_Get_Modelname(device); }
    if (!c->name) c->name = strdup("Android device");
    LIBMTP_Clear_Errorstack(device);
    return c;
}

void am_close(AMConnection *c) {
    if (!c) return;
    LIBMTP_Release_Device(c->device);
    free(c->name);
    free(c);
}
const char *am_device_name(AMConnection *c) { return c->name; }
const char *am_error(AMConnection *c) { return c->error; }

int am_storages(AMConnection *c, AMStorage **storages) {
    begin(c);
    *storages = NULL;
    if (LIBMTP_Get_Storage(c->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
        capture_error(c, "Could not read device storage."); return -1;
    }
    AMStorage **tail = storages;
    for (LIBMTP_devicestorage_t *s = c->device->storage; s; s = s->next) {
        AMStorage *copy = calloc(1, sizeof(*copy));
        if (!copy) { am_free_storages(*storages); *storages = NULL; return -1; }
        copy->id = s->id;
        copy->name = strdup(s->StorageDescription ? s->StorageDescription : "Device storage");
        copy->capacity = s->MaxCapacity;
        copy->free_bytes = s->FreeSpaceInBytes;
        copy->writable = s->AccessCapability == 0;
        *tail = copy;
        tail = &copy->next;
    }
    return 0;
}

void am_free_storages(AMStorage *s) {
    while (s) { AMStorage *next = s->next; free(s->name); free(s); s = next; }
}

int am_list(AMConnection *c, uint32_t storage, uint32_t parent, AMEntry **entries) {
    begin(c);
    *entries = NULL;
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(c->device, storage,
                                  parent == 0 ? LIBMTP_FILES_AND_FOLDERS_ROOT : parent);
    if (LIBMTP_Get_Errorstack(c->device)) {
        // Do not treat a partial listing as complete: collision checks rely on it.
        capture_error(c, "Could not read this folder completely.");
        while (files) {
            LIBMTP_file_t *next = files->next;
            files->next = NULL;
            LIBMTP_destroy_file_t(files);
            files = next;
        }
        return -1;
    }
    AMEntry **tail = entries;
    int status = 0;
    while (files) {
        LIBMTP_file_t *next = files->next;
        if (status == 0) {
            AMEntry *copy = calloc(1, sizeof(*copy));
            if (!copy) { status = -1; }
            else {
                copy->id = files->item_id;
                copy->parent = files->parent_id;
                copy->storage = files->storage_id;
                copy->name = strdup(files->filename ? files->filename : "Unnamed");
                copy->size = files->filesize;
                copy->modified = (int64_t)files->modificationdate;
                copy->is_folder = files->filetype == LIBMTP_FILETYPE_FOLDER;
                *tail = copy;
                tail = &copy->next;
            }
        }
        files->next = NULL;
        LIBMTP_destroy_file_t(files);
        files = next;
    }
    if (status != 0) {
        am_free_entries(*entries); *entries = NULL;
        snprintf(c->error, sizeof(c->error), "Not enough memory to read the folder.");
    }
    return status;
}

void am_free_entries(AMEntry *e) {
    while (e) { AMEntry *next = e->next; free(e->name); free(e); e = next; }
}

typedef struct {
    AMCancellation *cancel;
    AMProgress callback;
    void *context;
} ProgressContext;
static int progress(uint64_t sent, uint64_t total, const void *data) {
    const ProgressContext *p = data;
    if (p->callback) p->callback(sent, total, p->context);
    return am_is_cancelled(p->cancel);
}

int am_download(AMConnection *c, uint32_t object, const char *path,
                AMCancellation *cancel, AMProgress callback, void *context) {
    begin(c);
    if (am_is_cancelled(cancel)) return -1;
    ProgressContext p = { cancel, callback, context };
    int status = LIBMTP_Get_File_To_File(c->device, object, path, progress, &p);
    if (status != 0) capture_error(c, "Download failed.");
    return status;
}

int am_upload(AMConnection *c, uint32_t storage, uint32_t parent, const char *path,
              const char *name, uint64_t size, AMCancellation *cancel,
              AMProgress callback, void *context) {
    begin(c);
    if (am_is_cancelled(cancel)) return -1;
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    if (!file) return -1;
    file->filename = strdup(name);
    file->filesize = size;
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    file->storage_id = storage;
    file->parent_id = parent;
    ProgressContext p = { cancel, callback, context };
    int status = LIBMTP_Send_File_From_File(c->device, path, file, progress, &p);
    if (status != 0) {
        capture_error(c, "Upload failed.");
        // The library can leave an incomplete object after a cancelled send.
        if (file->item_id != 0) LIBMTP_Delete_Object(c->device, file->item_id);
    }
    LIBMTP_destroy_file_t(file);
    return status;
}

uint32_t am_create_folder(AMConnection *c, uint32_t storage, uint32_t parent, const char *name) {
    begin(c);
    char *mutable_name = strdup(name);
    uint32_t id = LIBMTP_Create_Folder(c->device, mutable_name, parent, storage);
    free(mutable_name);
    if (id == 0) capture_error(c, "Could not create the folder.");
    return id;
}

int am_rename(AMConnection *c, uint32_t object, int is_folder, const char *name) {
    begin(c);
    int status;
    if (is_folder) {
        LIBMTP_folder_t *folder = LIBMTP_new_folder_t();
        if (!folder) return -1;
        folder->folder_id = object;
        status = LIBMTP_Set_Folder_Name(c->device, folder, name);
        LIBMTP_destroy_folder_t(folder);
    } else {
        LIBMTP_file_t *file = LIBMTP_Get_Filemetadata(c->device, object);
        if (!file) { capture_error(c, "The file is no longer available."); return -1; }
        status = LIBMTP_Set_File_Name(c->device, file, name);
        LIBMTP_destroy_file_t(file);
    }
    if (status != 0) capture_error(c, "Could not rename the item.");
    return status;
}

int am_delete(AMConnection *c, uint32_t object) {
    begin(c);
    int status = LIBMTP_Delete_Object(c->device, object);
    if (status != 0) capture_error(c, "Could not delete the item.");
    return status;
}

AMCancellation *am_cancellation_new(void) {
    AMCancellation *c = malloc(sizeof(*c));
    if (c) atomic_init(&c->cancelled, 0);
    return c;
}
void am_cancellation_free(AMCancellation *c) { free(c); }
void am_cancel(AMCancellation *c) { if (c) atomic_store(&c->cancelled, 1); }
int am_is_cancelled(AMCancellation *c) { return c && atomic_load(&c->cancelled); }
