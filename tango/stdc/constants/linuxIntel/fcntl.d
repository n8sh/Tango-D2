module tango.stdc.constants.linuxIntel.fcntl;
version (linux) {
    version(SMALLFILE)  // Note: makes no difference in X86_64 mode.
    {
      const bool  __USE_LARGEFILE64   = false;
    }
    else
    {
      const bool  __USE_LARGEFILE64   = true;
    }
    const bool  __USE_FILE_OFFSET64 = __USE_LARGEFILE64;
    static if( __USE_FILE_OFFSET64 )
    {
    enum { F_GETLK = 12 }
    enum { F_SETLK = 13 }
    enum { F_SETLKW = 14 }
    }
    else
    {
    enum { F_GETLK = 5  }
    enum { F_SETLK = 6  }
    enum { F_SETLKW = 7 }
    }
}
enum { F_DUPFD = 0 }
enum { F_GETFD = 1 }
enum { F_SETFD = 2 }
enum { F_GETFL = 3 }
enum { F_SETFL = 4 }
enum { F_GETOWN = 9 }
enum { F_SETOWN = 8 }
enum { FD_CLOEXEC = 1 }
enum { F_RDLCK = 0 }
enum { F_UNLCK = 2 }
enum { F_WRLCK = 1 }
enum { O_CREAT = 0100  }
enum { O_EXCL = 0200  }
enum { O_NOCTTY = 0400 }
enum { O_TRUNC = 01000  }
enum { O_APPEND = 02000  }
enum { O_NONBLOCK = 04000 }
enum { O_SYNC = 010000  }
enum { O_DSYNC = 010000  } // optional synchronized io
enum { O_RSYNC = 010000  } // optional synchronized io
enum { O_ACCMODE = 0003 }
enum { O_RDONLY = 00  }
enum { O_WRONLY = 01  }
enum { O_RDWR = 02  }
