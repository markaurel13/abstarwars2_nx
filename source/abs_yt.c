/* abs_yt.c -- YouTube resolver stub */
#include "abs_net.h"
#include <stdio.h>
#include <string.h>

int abs_yt_resolve(const char *video_id, AbsYtStreams *out, char *err, size_t errsz) {
  if (err && errsz) snprintf(err, errsz, "no stream");
  if (out) memset(out, 0, sizeof(*out));
  return -1;
}

void abs_yt_free(AbsYtStreams *s) {
  (void)s;
}
