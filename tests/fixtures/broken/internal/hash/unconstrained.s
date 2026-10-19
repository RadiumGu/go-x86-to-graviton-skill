// No build constraint anywhere in this file.
#include "textflag.h"

TEXT ·bar(SB), NOSPLIT, $0
  MOVQ AX, BX
  RET
