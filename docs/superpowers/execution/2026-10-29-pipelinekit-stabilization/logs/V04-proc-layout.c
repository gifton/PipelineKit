#include <sys/proc_info.h>
#include <stddef.h>
#include <stdio.h>
int main(void) { printf("{\"size\":%zu,\"pid\":%zu,\"ppid\":%zu,\"pgid\":%zu,\"start_sec\":%zu,\"start_usec\":%zu}\n", sizeof(struct proc_bsdinfo), offsetof(struct proc_bsdinfo,pbi_pid), offsetof(struct proc_bsdinfo,pbi_ppid), offsetof(struct proc_bsdinfo,pbi_pgid), offsetof(struct proc_bsdinfo,pbi_start_tvsec), offsetof(struct proc_bsdinfo,pbi_start_tvusec)); }
