/* abs_net.c -- Network stub for ports without YouTube streaming */
#include "abs_net.h"
#include <stdio.h>

int abs_net_online(void) { return 0; }
void abs_net_abort_all(void) {}

AbsHttp *abs_http_open(const char *method, const char *url, const char *extra_headers, const void *body,
                       size_t body_len, int *status) {
  if (status) *status = 0;
  return NULL;
}

int64_t abs_http_length(const AbsHttp *h) { return -1; }
int abs_http_read(AbsHttp *h, void *buf, int n) { return -1; }
void abs_http_close(AbsHttp *h) { (void)h; }

char *abs_http_fetch(const char *method, const char *url, const char *extra_headers, const char *body,
                     size_t *len, int *status) {
  if (status) *status = 0;
  if (len) *len = 0;
  return NULL;
}
