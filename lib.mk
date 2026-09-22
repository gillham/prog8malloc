#
# Makefile fragment for malloc
#

malloclibdir	:= $(dir $(lastword $(MAKEFILE_LIST)))
PROG8_LIBS	+= prog8malloc
PROG8_LIBSRCS	+= $(malloclibdir)src/libmem.p8
PROG8_LIBSRCS	+= $(malloclibdir)src/$(platform)$(SEP)*.p8
PROG8_SRCDIRS	+= $(malloclibdir)src
PROG8_SRCDIRS	+= $(malloclibdir)src$(SEP)$(platform)

#
# end-of-file
#
