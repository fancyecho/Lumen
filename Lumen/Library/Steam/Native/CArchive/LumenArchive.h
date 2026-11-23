#ifndef LUMEN_ARCHIVE_H
#define LUMEN_ARCHIVE_H

#include <stddef.h>
#include <sys/types.h>

// macOS ships libarchive, but the SDK has no Clang module for its public reader API.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_filter_lzma(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_open_memory(struct archive *, const void *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_filter_code(struct archive *, int);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);

#endif
