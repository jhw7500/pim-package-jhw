#ifndef ORD_RECORDING_RETENTION_H
#define ORD_RECORDING_RETENTION_H

// Bounded, recording-only POSIX retention primitives. No shell or globbing.
// Returns number of files moved/deleted (>=0), or -1 on an I/O error.
// The caller must supply the trusted, fixed product path constants.
namespace ord_retention {
int rotate_oldest(const char *recording_root, const char *recycle_root,
                  const char *vhl_name, const char *muxer);
int prune_recycle(const char *recycle_root,
                  const char *vhl_name, const char *muxer);
int prune_recording(const char *recording_root,
                    const char *vhl_name, const char *muxer);
int prune_event(const char *event_root,
                const char *vhl_name, const char *muxer);
}

#endif
