#ifndef MTP_BRIDGE_H
#define MTP_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct AMConnection AMConnection;
typedef struct AMCancellation AMCancellation;
typedef void (*AMProgress)(uint64_t completed, uint64_t total, void *context);

typedef struct AMDevice {
    uint32_t bus;
    uint8_t number;
    char *name;
    struct AMDevice *next;
} AMDevice;

typedef struct AMStorage {
    uint32_t id;
    char *name;
    uint64_t capacity;
    uint64_t free_bytes;
    int writable;
    struct AMStorage *next;
} AMStorage;

typedef struct AMEntry {
    uint32_t id;
    uint32_t parent;
    uint32_t storage;
    char *name;
    uint64_t size;
    int64_t modified;
    int is_folder;
    struct AMEntry *next;
} AMEntry;

int am_detect(AMDevice **devices, char *error, size_t error_capacity);
void am_free_devices(AMDevice *devices);
AMConnection *am_open(uint32_t bus, uint8_t number, char *error, size_t error_capacity);
void am_close(AMConnection *connection);
const char *am_device_name(AMConnection *connection);
const char *am_error(AMConnection *connection);
int am_storages(AMConnection *connection, AMStorage **storages);
void am_free_storages(AMStorage *storages);
int am_list(AMConnection *connection, uint32_t storage, uint32_t parent, AMEntry **entries);
void am_free_entries(AMEntry *entries);
int am_download(AMConnection *, uint32_t object, const char *path,
                AMCancellation *, AMProgress, void *context);
int am_upload(AMConnection *, uint32_t storage, uint32_t parent, const char *path,
              const char *name, uint64_t size, AMCancellation *, AMProgress, void *context);
uint32_t am_create_folder(AMConnection *, uint32_t storage, uint32_t parent, const char *name);
int am_rename(AMConnection *, uint32_t object, int is_folder, const char *name);
int am_delete(AMConnection *, uint32_t object);
AMCancellation *am_cancellation_new(void);
void am_cancellation_free(AMCancellation *);
void am_cancel(AMCancellation *);
int am_is_cancelled(AMCancellation *);
#endif
