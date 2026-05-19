package Slight;

use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';

use constant DEBUG       => exists $ENV{DEBUG} ? $ENV{DEBUG}+0 : 0;
use constant DEBUG_STEP  => DEBUG >= 1 || !!$ENV{DEBUG_STEP};
use constant DEBUG_BIND  => DEBUG >= 2 || !!$ENV{DEBUG_BIND};
use constant DEBUG_CALL  => DEBUG >= 2 || !!$ENV{DEBUG_CALL};
use constant DEBUG_QUEUE => DEBUG >= 3 || !!$ENV{DEBUG_QUEUE};

use Slight::Allocator;
use Slight::Effect;
use Slight::Machine;
use Slight::Parser;
use Slight::Runtime;
use Slight::Term;

use if DEBUG => qw[ Slight::Tools::Debug ];

