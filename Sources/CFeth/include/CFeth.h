// SPDX-License-Identifier: GPL-2.0-or-later
// Swift cannot import function-like ioctl macros or private kernel structs, so this
// shim re-exports the pieces the feth/BPF backend needs as plain constants and types.

#ifndef CFETH_H
#define CFETH_H

#include <stdint.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/ioccom.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/bpf.h>
#include <net/ndrv.h>
#include <netinet/in.h>

// From XNU bsd/net/if_fake_var.h, which the macOS SDK does not ship.
// Layout must match the kernel exactly: 32 reserved bytes then a 128-byte union.
#define CFETH_IF_FAKE_S_CMD_SET_PEER 1

struct cfeth_if_fake_request {
    uint64_t iffr_reserved[4];
    union {
        char iffru_buf[128];
        char iffru_peer_name[IFNAMSIZ];
        uint32_t iffru_dequeue_stall;
    } iffr_u;
};

// struct ifdrv is not visible in every SDK, so carry our own with the kernel layout.
struct cfeth_ifdrv {
    char ifd_name[IFNAMSIZ];
    unsigned long ifd_cmd;
    size_t ifd_len;
    void *ifd_data;
};

static const unsigned long CFETH_SIOCIFCREATE = SIOCIFCREATE;
static const unsigned long CFETH_SIOCIFDESTROY = SIOCIFDESTROY;
static const unsigned long CFETH_SIOCSIFLLADDR = SIOCSIFLLADDR;
static const unsigned long CFETH_SIOCSIFMTU = SIOCSIFMTU;
static const unsigned long CFETH_SIOCGIFFLAGS = SIOCGIFFLAGS;
static const unsigned long CFETH_SIOCSIFFLAGS = SIOCSIFFLAGS;
static const unsigned long CFETH_SIOCGIFADDR = SIOCGIFADDR;

// SIOCSDRVSPEC may be absent from the public SDK; computing it from our struct
// yields the identical request code because _IOW encodes the argument size.
static const unsigned long CFETH_SIOCSDRVSPEC = _IOW('i', 123, struct cfeth_ifdrv);

static const unsigned long CFETH_BIOCSBLEN = BIOCSBLEN;
static const unsigned long CFETH_BIOCSETIF = BIOCSETIF;
static const unsigned long CFETH_BIOCSHDRCMPLT = BIOCSHDRCMPLT;
static const unsigned long CFETH_BIOCGDLT = BIOCGDLT;
static const unsigned long CFETH_BIOCIMMEDIATE = BIOCIMMEDIATE;
static const unsigned long CFETH_BIOCSSEESENT = BIOCSSEESENT;
static const unsigned long CFETH_BIOCSRTIMEOUT = BIOCSRTIMEOUT;
static const unsigned long CFETH_BIOCPROMISC = BIOCPROMISC;

// Batch write mode from XNU bsd/net/bpf_private.h (macOS 14+, not in the SDK).
// One write(2) carries [struct bpf_hdr + packet + BPF_WORDALIGN pad] records;
// requires BIOCSHDRCMPLT to be set first. Feature-detected at runtime.
static const unsigned long CFETH_BIOCSBATCHWRITE = _IOW('B', 143, int);

// Variadic ioctl(2) does not import into Swift; expose a fixed-arity wrapper.
static inline int cfeth_ioctl(int fd, unsigned long request, void *arg) {
    return ioctl(fd, request, arg);
}

static inline size_t cfeth_bpf_wordalign(size_t length) {
    return BPF_WORDALIGN(length);
}

#endif
