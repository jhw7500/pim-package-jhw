#include "recording_retention.h"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <sys/syscall.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace ord_retention {
namespace {
const time_t kMinAgeSeconds = 300;  // never prune currently recording sessions
const size_t kMaxFilesPerPass = 32;

class DirFd {
 public:
  explicit DirFd(const char *path)
      : fd_(path ? open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1) {}
  DirFd(int parent, const char *name)
      : fd_(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) {}
  ~DirFd() { if (fd_ >= 0) close(fd_); }
  int get() const { return fd_; }
 private:
  int fd_;
  DirFd(const DirFd &);
  DirFd &operator=(const DirFd &);
};

struct Candidate {
  std::string name;
  std::string hour;
  std::string minute;
  time_t modified;
  ino_t inode;
  dev_t device;
  off_t size;
  struct timespec mtime_exact;
  struct timespec ctime_exact;
};

bool token(const char *value, size_t max_size) {
  if (!value) return false;
  // Do not let std::string(char*) scan beyond a fixed-size product
  // configuration field when a malformed value lacks a NUL terminator.
  size_t length = 0;
  while (length <= max_size && value[length] != '\0') ++length;
  if (length == 0 || length > max_size) return false;
  const std::string s(value, length);
  for (size_t i = 0; i < s.size(); ++i) {
    const unsigned char c = static_cast<unsigned char>(s[i]);
    if (!(std::isalnum(c) || c == '_' || c == '-')) return false;
  }
  return true;
}

bool policy(const char *vhl, const char *muxer) {
  return token(vhl, 63) && token(muxer, 10)
      && (std::string(muxer) == "mp4" || std::string(muxer) == "ts"
          || std::string(muxer) == "mkv");
}

bool digits(const std::string &s, size_t start, size_t size) {
  if (start + size > s.size()) return false;
  for (size_t i = start; i < start + size; ++i)
    if (s[i] < '0' || s[i] > '9') return false;
  return true;
}

int decimal(const std::string &s, size_t pos, size_t size) {
  int value = 0;
  for (size_t i = pos; i < pos + size; ++i) value = value * 10 + s[i] - '0';
  return value;
}

// Check the actual timestamp shape, not just the presence of the machine ID.
bool valid_calendar_day(int year, int month, int day) {
  if (year < 2000 || year > 2099 || month < 1 || month > 12) return false;
  static const int days[] = {0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  const bool leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  return day >= 1 && day <= days[month] + (leap && month == 2 ? 1 : 0);
}

bool timestamp(const std::string &s, size_t pos) {
  if (!digits(s, pos, 8) || pos + 8 >= s.size() || s[pos + 8] != '_'
      || !digits(s, pos + 9, 6)) return false;
  const int y = decimal(s, pos, 4), mo = decimal(s, pos + 4, 2);
  const int day = decimal(s, pos + 6, 2), h = decimal(s, pos + 9, 2);
  const int m = decimal(s, pos + 11, 2), sec = decimal(s, pos + 13, 2);
  return valid_calendar_day(y, mo, day) && h <= 23 && m <= 59 && sec <= 59;
}

bool hour_name(const std::string &name) {
  if (name.size() != 11 || !digits(name, 0, 8) || name[8] != '_'
      || !digits(name, 9, 2)) return false;
  const int year = decimal(name, 0, 4), mo = decimal(name, 4, 2);
  const int day = decimal(name, 6, 2), hour = decimal(name, 9, 2);
  return valid_calendar_day(year, mo, day) && hour <= 23;
}

bool file_name(const std::string &name, const char *vhl, const char *muxer,
               bool event, std::string *hour, std::string *minute) {
  const std::string prefix = (event ? "evt_" : "") + std::string(vhl) + "_";
  if (name.compare(0, prefix.size(), prefix) != 0) return false;
  const size_t pos = prefix.size();
  if (!timestamp(name, pos)) return false;
  std::string suffix = name.substr(pos + 15);
  // ORD's COPY worker optionally inserts _rmsMax_<N.N> immediately
  // before -chN/-data/-vib when vibration is enabled.
  if (event && suffix.compare(0, 8, "_rmsMax_") == 0) {
    size_t i = 8;
    if (i < suffix.size() && suffix[i] == '-') ++i;
    const size_t digits_start = i;
    while (i < suffix.size() && suffix[i] >= '0' && suffix[i] <= '9') ++i;
    if (i == digits_start || i - digits_start > 10
        || i + 1 >= suffix.size() || suffix[i] != '.'
        || suffix[i + 1] < '0' || suffix[i + 1] > '9') return false;
    suffix = suffix.substr(i + 2);
  }
  const bool video = suffix.size() == 5 + std::string(muxer).size()
      && suffix.compare(0, 3, "-ch") == 0
      && suffix[3] >= '0' && suffix[3] <= '3'
      && suffix[4] == '.' && suffix.substr(5) == muxer;
  if (!video && suffix != "-data.srt" && suffix != "-vib.bin") return false;
  if (hour) *hour = name.substr(pos, 11);
  if (minute) *minute = name.substr(pos, 13);
  return true;
}

// The on-disk mtime may have been backdated while a current recording session
// is still active. Protect recent/future timestamped sessions independently.
// Both interpretations of the repeated local hour at DST fall-back must be
// old before cleanup: a lexicographic localtime comparison is not sufficient.
// This guard is NOT an attestation that all recorder write FDs are closed.
bool old_session_name(const std::string &name, const char *vhl,
                      bool event, time_t now) {
  if (now <= kMinAgeSeconds) return false;
  const size_t pos = std::string(vhl).size() + (event ? 5 : 1);
  if (name.size() < pos + 15) return false;
  const int year = decimal(name, pos, 4), month = decimal(name, pos + 4, 2);
  const int day = decimal(name, pos + 6, 2), hour = decimal(name, pos + 9, 2);
  const int minute = decimal(name, pos + 11, 2), second = decimal(name, pos + 13, 2);
  bool interpreted = false;
  for (int is_dst = 0; is_dst <= 1; ++is_dst) {
    struct tm when = {};
    when.tm_year = year - 1900;
    when.tm_mon = month - 1;
    when.tm_mday = day;
    when.tm_hour = hour;
    when.tm_min = minute;
    when.tm_sec = second;
    when.tm_isdst = is_dst;
    const time_t epoch = mktime(&when);
    if (epoch == static_cast<time_t>(-1) || when.tm_year != year - 1900
        || when.tm_mon != month - 1 || when.tm_mday != day
        || when.tm_hour != hour || when.tm_min != minute
        || when.tm_sec != second) continue;
    interpreted = true;
    if (epoch >= now - kMinAgeSeconds) return false;
  }
  return interpreted;
}

bool older_than_grace(const struct stat &st, time_t now) {
  return S_ISREG(st.st_mode) && st.st_mtime > 0 && now > st.st_mtime
      && now - st.st_mtime >= kMinAgeSeconds;
}

bool candidate_order(const Candidate &a, const Candidate &b) {
  if (a.modified != b.modified) return a.modified < b.modified;
  return a.name < b.name;
}

int eligible_files(int fd, const char *vhl, const char *muxer, bool event,
                   const std::string &hour_filter,
                   std::vector<Candidate> *files) {
  const int copy = dup(fd);
  if (copy < 0) return -1;
  DIR *dir = fdopendir(copy);
  if (!dir) { close(copy); return -1; }
  const time_t now = time(NULL);
  int read_error = 0;
  for (;;) {
    // Only errno from readdir() itself represents an iteration error.
    // mktime() and fstatat() within the loop are allowed to change errno.
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (!entry) { read_error = errno; break; }
    const std::string name(entry->d_name);
    std::string hour, minute;
    if (!file_name(name, vhl, muxer, event, &hour, &minute)
        || (!hour_filter.empty() && hour != hour_filter)) continue;
    if (!old_session_name(name, vhl, event, now)) continue;
    struct stat st;
    if (fstatat(fd, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) != 0
        || !older_than_grace(st, now)) continue;
    Candidate item = {name, hour, minute, st.st_mtime, st.st_ino,
                      st.st_dev, st.st_size, st.st_mtim, st.st_ctim};
    files->push_back(item);
  }
  closedir(dir);
  if (read_error) return -1;
  std::sort(files->begin(), files->end(), candidate_order);
  return 0;
}

// Never unlink a pathname solely because it passed a prior fstatat: a
// producer may replace it before the unlinkat/renameat2 call. First move to
// a restricted same-filesystem quarantine and check the moved inode itself.
const char *const kQuarantine = ".ord-retention-quarantine";

int move_noreplace(int src_fd, const char *src, int dst_fd, const char *dst) {
#ifdef SYS_renameat2
  return static_cast<int>(syscall(SYS_renameat2, src_fd, src, dst_fd, dst,
                                  RENAME_NOREPLACE));
#else
  (void)src_fd; (void)src; (void)dst_fd; (void)dst;
  errno = ENOSYS;
  return -1;
#endif
}

// Rename can change ctime even when file contents are unchanged. Compare
// identity, size, mtime and age instead, after moving the actual inode.
bool same_moved_file(int fd, const Candidate &file) {
  struct stat st;
  return fstatat(fd, file.name.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0
      && S_ISREG(st.st_mode) && st.st_ino == file.inode
      && st.st_dev == file.device && st.st_size == file.size
      && st.st_mtim.tv_sec == file.mtime_exact.tv_sec
      && st.st_mtim.tv_nsec == file.mtime_exact.tv_nsec
      && older_than_grace(st, time(NULL));
}

bool empty_dir(int fd) {
  const int copied = dup(fd);
  if (copied < 0) return false;
  DIR *dir = fdopendir(copied);
  if (!dir) { close(copied); return false; }
  bool empty = true;
  int read_error = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (!entry) { read_error = errno; break; }
    if (std::string(entry->d_name) != "."
        && std::string(entry->d_name) != "..") { empty = false; break; }
  }
  closedir(dir);
  return empty && read_error == 0;
}

struct RemoveEmptyQuarantine {
  explicit RemoveEmptyQuarantine(int parent) : parent_(parent) {}
  ~RemoveEmptyQuarantine() {
    // RMDIR cannot remove the directory if any unverified file remains.
    (void)unlinkat(parent_, kQuarantine, AT_REMOVEDIR);
  }
 private:
  int parent_;
};

// Refuse a candidate whose identity, size, or modification metadata changed
// during the directory scan. This narrows, but cannot eliminate, the residual
// pathname replacement race after the final check; board acceptance must
// still verify recorder ownership and the cleanup/recording session boundary.
bool same_regular_file(int fd, const Candidate &file) {
  struct stat st;
  return fstatat(fd, file.name.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0
      && S_ISREG(st.st_mode) && st.st_ino == file.inode
      && st.st_dev == file.device && st.st_size == file.size
      && st.st_mtim.tv_sec == file.mtime_exact.tv_sec
      && st.st_mtim.tv_nsec == file.mtime_exact.tv_nsec
      && st.st_ctim.tv_sec == file.ctime_exact.tv_sec
      && st.st_ctim.tv_nsec == file.ctime_exact.tv_nsec
      && older_than_grace(st, time(NULL));
}

int prune_files(int fd, const std::vector<Candidate> &files,
                const std::string &minute_filter) {
  if (mkdirat(fd, kQuarantine, 0700) != 0 && errno != EEXIST) return -1;
  DirFd stage(fd, kQuarantine);
  struct stat stage_stat;
  if (stage.get() < 0 || fstat(stage.get(), &stage_stat) != 0
      || !S_ISDIR(stage_stat.st_mode)
      || stage_stat.st_uid != geteuid()
      || (stage_stat.st_mode & 077) != 0) return -1;
  RemoveEmptyQuarantine cleanup(fd);
  // A previous interrupted operation may have left a file here. Preserve it.
  if (!empty_dir(stage.get())) return -1;
  int removed = 0;
  for (size_t i = 0; i < files.size() && removed < static_cast<int>(kMaxFilesPerPass); ++i) {
    const Candidate &file = files[i];
    if (!minute_filter.empty() && file.minute != minute_filter) continue;
    if (!same_regular_file(fd, file)) continue;
    if (move_noreplace(fd, file.name.c_str(), stage.get(), file.name.c_str()) != 0)
      return -1;
    if (!same_moved_file(stage.get(), file)) {
      // If the source name is no longer free, an unverified object stays
      // quarantined for manual recovery. Never delete it.
      (void)move_noreplace(stage.get(), file.name.c_str(), fd, file.name.c_str());
      return -1;
    }
    if (unlinkat(stage.get(), file.name.c_str(), 0) != 0) return -1;
    ++removed;
  }
  return removed;
}

}  // namespace

int rotate_oldest(const char *root, const char *recycle,
                  const char *vhl, const char *muxer) {
  if (!policy(vhl, muxer)) return -1;
  DirFd src(root), dst(recycle);
  if (src.get() < 0 || dst.get() < 0) return -1;
  std::vector<Candidate> files;
  if (eligible_files(src.get(), vhl, muxer, false, "", &files) < 0) return -1;
  if (files.empty()) return 0;
  const std::string hour = files[0].hour;
  if (mkdirat(dst.get(), hour.c_str(), 0700) < 0 && errno != EEXIST) return -1;
  DirFd hour_dir(dst.get(), hour.c_str());
  if (hour_dir.get() < 0) return -1;
  int moved = 0;
  for (size_t i = 0; i < files.size() && moved < static_cast<int>(kMaxFilesPerPass); ++i) {
    const Candidate &f = files[i];
    if (f.hour != hour || !same_regular_file(src.get(), f)) continue;
    // A single atomic move prevents a successful link followed by an
    // unrelated source-file replacement before unlink. Never replace an
    // existing destination recording; unsupported filesystems fail closed.
    if (move_noreplace(src.get(), f.name.c_str(),
                       hour_dir.get(), f.name.c_str()) != 0) return -1;
    if (!same_moved_file(hour_dir.get(), f)) {
      // Do not keep an unexpected object as a valid recording.
      // Try a no-overwrite rollback; on collision preserve it in recycle.
      (void)move_noreplace(hour_dir.get(), f.name.c_str(),
                           src.get(), f.name.c_str());
      return -1;
    }
    ++moved;
  }
  return moved;
}

int prune_recycle(const char *recycle, const char *vhl, const char *muxer) {
  if (!policy(vhl, muxer)) return -1;
  DirFd root(recycle);
  if (root.get() < 0) return -1;
  const int copy = dup(root.get());
  if (copy < 0) return -1;
  DIR *dir = fdopendir(copy);
  if (!dir) { close(copy); return -1; }
  std::vector<std::string> hours;
  errno = 0;
  while (struct dirent *entry = readdir(dir)) {
    const std::string name(entry->d_name);
    if (!hour_name(name)) continue;
    struct stat st;
    if (fstatat(root.get(), name.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0
        && S_ISDIR(st.st_mode)) hours.push_back(name);
    errno = 0;
  }
  const int saved_errno = errno;
  closedir(dir);
  if (saved_errno) return -1;
  std::sort(hours.begin(), hours.end());
  for (size_t i = 0; i < hours.size(); ++i) {
    DirFd hour(root.get(), hours[i].c_str());
    if (hour.get() < 0) continue;
    std::vector<Candidate> files;
    if (eligible_files(hour.get(), vhl, muxer, false, hours[i], &files) < 0) return -1;
    if (files.empty()) continue;
    const int n = prune_files(hour.get(), files, "");
    if (n < 0) return -1;
    // Only remove the directory when empty; any unknown file keeps it intact.
    (void)unlinkat(root.get(), hours[i].c_str(), AT_REMOVEDIR);
    return n;
  }
  return 0;
}

int prune_recording(const char *root, const char *vhl, const char *muxer) {
  if (!policy(vhl, muxer)) return -1;
  DirFd dir(root);
  if (dir.get() < 0) return -1;
  std::vector<Candidate> files;
  if (eligible_files(dir.get(), vhl, muxer, false, "", &files) < 0) return -1;
  if (files.empty()) return 0;
  return prune_files(dir.get(), files, files[0].minute);
}

int prune_event(const char *root, const char *vhl, const char *muxer) {
  if (!policy(vhl, muxer)) return -1;
  DirFd dir(root);
  if (dir.get() < 0) return -1;
  std::vector<Candidate> files;
  if (eligible_files(dir.get(), vhl, muxer, true, "", &files) < 0) return -1;
  if (files.empty()) return 0;
  return prune_files(dir.get(), files, files[0].minute);
}
}  // namespace ord_retention
