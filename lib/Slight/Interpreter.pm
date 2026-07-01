use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

## -----------------------------------------------------------------------------
## INTERPRETER NOTES
## -----------------------------------------------------------------------------
## - Unify error handling between interpreters
## - consider a "stack allocator" for temporary values (
##      - especially Cons cells and temp Nums during calculations
## -----------------------------------------------------------------------------
