// Copyright placeholder.
// Line 2 of a license header.
// Line 3.
// Line 4.
// Line 5 - a head -5 check stops reading here, which is the point.
// Line 6.
// Line 7.
// +build amd64

#include "textflag.h"

TEXT ·foo(SB), NOSPLIT, $0
  MOVQ AX, BX
  RET
