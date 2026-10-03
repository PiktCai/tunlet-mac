// Compatibility shim adapted from docker-easyconnect/fake-getlogin (WTFPL).
#define _GNU_SOURCE
#include <errno.h>
#include <stdlib.h>
#include <string.h>

int getlogin_r(char *buf, size_t bufsize) {
  const char *login = getenv("FAKE_LOGIN");
  if (!login)
    return ENXIO;
  size_t len = strlen(login);
  if (len + 1 > bufsize)
    return ERANGE;
  strcpy(buf, login);
  return 0;
}

const char *getlogin(void) {
  const char *login = getenv("FAKE_LOGIN");
  return login ? login : 0;
}
