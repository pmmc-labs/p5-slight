package Slight;
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Data::Dumper qw[ Dumper ];
use Time::HiRes  qw[ gettimeofday tv_interval ];
use Sub::Util    qw[ set_subname ];
use List::Util   qw[ sum ];

use constant DEBUG => $ENV{DEBUG} // 0;

use Term::ReadKey ();
our $TERM_WIDTH = (Term::ReadKey::GetTerminalSize)[0] // 300;

use Slight::Allocator;
use Slight::Parser;
use Slight::Compiler;

use Slight::Interpreter::ASTWalker;
use Slight::Interpreter::CEK;

## -----------------------------------------------------------------------------
## RUNTIME NOTES
## -----------------------------------------------------------------------------
## - Create runtime layer to manage:
##      - the central allocator
##      - the BIF environment
##          - and the lift*Op helpers
##      - parsing/compiling code
##      - top-level namespace management
##          - handling loading code from modules, etc.
##      - running different interpreters
##          - possibly comparing outputs
##      - dumping stats, etc.
## - some other ideas ...
##      - Add a REPL
##      - Add a CLI
##      - Create a test harness and test framework
##          - create a new "TopLevelEnv" with testing functions in it
##      - add I/O channels for interpreters to read/write to/from
## -----------------------------------------------------------------------------

sub run ($config, $source) {
    my $alloc    = Allocator->new;
    my $parser   = Parser->new( alloc => $alloc );
    my $compiler = Compiler->new( alloc => $alloc );

    my $parsed           = $parser->parse( $source );
    my $bifs             = init_builtins($alloc);
    my ($compiled, $env) = $compiler->compile( $parsed, $bifs );


    DUMP_PARSER($alloc, $source, $parsed)  if $config->{dump_parser};
    DUMP_COMPILER($alloc, $compiled, $env) if $config->{dump_compiler};

    my $ast_result;
    if ($config->{run_ast}) {
        my $elapsed;
        ($ast_result, $elapsed) = run_ASTWalker( $alloc, $compiled, $env );
        DUMP_RESULT($alloc, AST => $ast_result, $elapsed) if $config->{dump_results};
    }

    my $cek_result;
    if ($config->{run_cek}) {
        my $elapsed;
        ($cek_result, $elapsed) = run_CEK( $alloc, $compiled, $env );
        DUMP_RESULT($alloc, CEK => $cek_result, $elapsed) if $config->{dump_results};
    }

    DUMP_MEMORY_STATS($alloc) if $config->{dump_memory_stats};
    DUMP_MEMORY($alloc)       if $config->{dump_memory};

    return grep defined $_, ($ast_result, $cek_result)
}

sub run_ASTWalker ($alloc, $compiled, $env) {
    my $ast     = Interpreter::ASTWalker->new( alloc => $alloc );
    my $start   = [gettimeofday];
    my $evaled  = $ast->run( $compiled, $env );
    my $elapsed = tv_interval ( $start, [gettimeofday]);
    return $evaled, $elapsed;
}

sub run_CEK ($alloc, $compiled, $env) {
    my $cek     = Interpreter::CEK->new( alloc => $alloc );
    my $start   = [gettimeofday];
    my $evaled  = $cek->run( $compiled, $env );
    my $elapsed = tv_interval ( $start, [gettimeofday]);
    return $evaled, $elapsed;
}

sub init_builtins ($alloc) {
    return $alloc->Util->InitEnv(
        liftBoolBinOp($alloc, '==', sub ($n, $m) { $n == $m }),
        liftBoolBinOp($alloc, '!=', sub ($n, $m) { $n != $m }),
        liftBoolBinOp($alloc, '>',  sub ($n, $m) { $n >  $m }),
        liftBoolBinOp($alloc, '>=', sub ($n, $m) { $n >= $m }),
        liftBoolBinOp($alloc, '<',  sub ($n, $m) { $n <  $m }),
        liftBoolBinOp($alloc, '<=', sub ($n, $m) { $n <= $m }),

        liftNumBinOp($alloc, '+', sub ($n, $m) { $n + $m }),
        liftNumBinOp($alloc, '-', sub ($n, $m) { $n - $m }),
        liftNumBinOp($alloc, '*', sub ($n, $m) { $n * $m }),
        liftNumBinOp($alloc, '/', sub ($n, $m) { $n / $m }),
        liftNumBinOp($alloc, '%', sub ($n, $m) { $n % $m }),

        liftTermBinOp($alloc, 'eq?', sub ($n, $m) { $alloc->Bool(  $n->equal_to($m) ) }),
        liftTermBinOp($alloc, 'ne?', sub ($n, $m) { $alloc->Bool( !$n->equal_to($m) ) }),

        liftTermListOp($alloc, 'list', sub (@items) { $alloc->Util->ListOf(@items) }),
        liftTermBinOp ($alloc, 'cons', sub ($h, $t) { $alloc->Cons( $h, $t )       }),
        liftTermUnOp  ($alloc, 'nil?', sub ($t)     { $alloc->Bool( $t->is_nil )   }),
        liftTermUnOp  ($alloc, 'head', sub ($l)     { $alloc->Util->Head($l)       }),
        liftTermUnOp  ($alloc, 'tail', sub ($l)     { $alloc->Util->Tail($l)       }),
    )
}

sub liftBoolBinOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/BinOp/Bool/${op}" => sub ($args) {
        my ($n, $m) = $alloc->Util->Uncons($args);
        return $alloc->Bool( $f->( $n->value, $m->value ) );
    })
}

sub liftNumBinOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/BinOp/Num/${op}" => sub ($args) {
        my ($n, $m) = $alloc->Util->Uncons($args);
        return $alloc->Num( $f->( $n->value, $m->value ) );
    })
}

sub liftTermBinOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/BinOp/*/${op}" => sub ($args) {
        my ($n, $m) = $alloc->Util->Uncons($args);
        return $f->( $n, $m );
    })
}

sub liftTermUnOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/UnOp/*/${op}" => sub ($args) {
        my $n = $alloc->Util->Head($args);
        return $f->( $n );
    })
}

sub liftTermListOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/ListOp/*/${op}" => sub ($args) {
        my @args = $alloc->Util->Uncons($args);
        return $f->( @args );
    })
}

sub DUMP_PARSER ($alloc, $source, $parsed) {
    say '=' x $TERM_WIDTH;
    say 'SOURCE:';
    say '-' x $TERM_WIDTH;
    say $source;
    say '';
    say '=' x $TERM_WIDTH;
    say 'PARSED:';
    say '-' x $TERM_WIDTH;
    say $alloc->Util->DUMP($_) foreach @$parsed;
    say '=' x $TERM_WIDTH;
}

sub DUMP_COMPILER ($alloc, $compiled, $env) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'COMPILED:';
    say '-' x $TERM_WIDTH;
    # TODO - also dump ENV here ...
    say $alloc->Util->DUMP($_) foreach @$compiled;
    say '=' x $TERM_WIDTH;
}

sub DUMP_RESULT ($alloc, $type, $result, $elapsed) {
    say '';
    say '=' x $TERM_WIDTH;
    say sprintf 'GOT RESULT(%s) completed in %f seconds', $type, $elapsed;
    say '-' x $TERM_WIDTH;
    say $alloc->Util->DUMP($result);
    say '=' x $TERM_WIDTH;
}

sub DUMP_MEMORY_STATS ($alloc) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'STATS:';
    say '-' x $TERM_WIDTH;
    my $stats = $alloc->stats;

    my $total_requests   = $stats->{total_requests};
    my $total_created    = $stats->{total_created};
    my $requests_by_hash = $stats->{requests_by_hash};
    my $created_by_type  = $stats->{created_by_type};

    say sprintf '  total_requests : %d' => $total_requests;
    say sprintf '  total_created  : %d' => $total_created;
    say sprintf '  total created  : (by type)';
    my @sorted_types = sort { $created_by_type->{$b} <=> $created_by_type->{$a} } keys $created_by_type->%*;
    say '    +-----------+----------+';
    say '    | type      | count    |';
    say '    +-----------+----------+';
    foreach my $key (@sorted_types) {
        say sprintf '    | %-9s | %-8d |', $key, $created_by_type->{$key};
    }
    say '    +-----------+----------+';
    say sprintf '  top-K requests : (by hash)';
    my $filtered = 0;
    my @sorted_hashes =
        map {
            if ($requests_by_hash->{$_} < 10) {
                $filtered++;
                ();
            } else {
                $_
            }
        }
        sort { $requests_by_hash->{$b} <=> $requests_by_hash->{$a} }
        keys $requests_by_hash->%*;
    say '    +--------+----------+';
    say '    | hash   | count    |';
    say '    +--------+----------+';
    foreach my $hash (@sorted_hashes) {
        say sprintf '    | %s | %-8d | %s', substr($hash, 0, 6), $requests_by_hash->{$hash}, substr($alloc->Util->pprint($alloc->deref_hash($hash)), 0, $TERM_WIDTH - 26);
    }
    say         '    +--------+----------+';
    say sprintf '    |  < 10  | %-8d |' => $filtered;
    say         '    +--------+----------+';
    say '=' x $TERM_WIDTH;
}

sub DUMP_MEMORY ($alloc) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'MEMORY:';
    say '-' x $TERM_WIDTH;
    say $alloc->Util->DUMP($_) foreach $alloc->memory;
    say '=' x $TERM_WIDTH;
}


