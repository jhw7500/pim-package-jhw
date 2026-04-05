#ifndef __APP_ENCRYPT_H__
#define __APP_ENCRYPT_H__

#ifdef __cplusplus
extern "C" {
#endif

#define MAX_PASSWD_STRING	(1024)

//-------------------------------------------------------------------------
int encrypt_get_passwd(char *filename, char *passwd);
int encrypt_change_passwd(char *filename, char *cur_passwd, char *change_passwd);

#ifdef __cplusplus
}
#endif
#endif
