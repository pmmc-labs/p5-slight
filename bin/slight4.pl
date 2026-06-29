use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Data::Dumper qw[ Dumper ];

use constant DEBUG => $ENV{DEBUG} // 0;
use Term::ReadKey (); our $TERM_WIDTH = (Term::ReadKey::GetTerminalSize)[0];

use Digest::MD5 ();

## -----------------------------------------------------------------------------

class Term {
    field $index :param :reader;
    field $hash  :param :reader;
    field $data  :param :reader;

    method is_nil { false }
}
class Sym     :isa(Term) { method ident { $self->data->[0] } }
class Str     :isa(Term) { method value { $self->data->[0] } }
class Num     :isa(Term) { method value { $self->data->[0] } }
class Bool    :isa(Term) { method value { $self->data->[0] } }
class Nil     :isa(Term) { method is_nil { true } }
class Cons    :isa(Term) {
    method head { $self->data->[0] }
    method tail { $self->data->[1] }
}

## -----------------------------------------------------------------------------

class Index { field $idx :param :reader; }

class Allocator {
    field @memory :reader;
    field %intern :reader;

    field $Nil;
    field $True;
    field $False;

    my method intern ($type, @payload) {
        my $hash  = Digest::MD5::md5_hex( join '/' => $type, join ':' => @payload );
        return $memory[ $intern{ $hash } ] if exists $intern{ $hash };
        my $index = scalar @memory;
        my $value = $type->new(
            index => Index->new( idx => $index ),
            hash  => $hash,
            data  => [ map blessed $_ ? $_->index : $_, @payload ]
        );
        push @memory => $value;
        $intern{ $hash } = $index;
        return $value;
    }

    ADJUST {
        $Nil   = $self->&intern( Nil  => '#nil'   );
        $True  = $self->&intern( Bool => '#true'  );
        $False = $self->&intern( Bool => '#false' );
    }

    method Nil   { $Nil }
    method True  { $True }
    method False { $False }

    method Bool ($value) { $value ? $True : $False }
    method Sym  ($ident) { $self->&intern( Sym  => $ident ) }
    method Num  ($value) { $self->&intern( Num  => $value ) }
    method Str  ($value) { $self->&intern( Str  => $value ) }
    method Cons ($h, $t) { $self->&intern( Cons => $h, $t ) }

    method List (@list) {
        my $list = $Nil;
        while (@list) {
            $list = $self->Cons( pop @list, $list );
        }
        return $list;
    }

    ## ... utils

    method deref ($index) { $memory[ $index->idx ] }

    method uncons ($list) {
        my @list;
        until ($list->is_nil) {
            push @list => $self->deref( $list->head );
            $list = $self->deref( $list->tail );
        }
        return @list;
    }

    method pprint ($t) {
        given (blessed $t) {
            when ('Sym')  { $t->ident }
            when ('Str')  { $t->value }
            when ('Num')  { $t->value }
            when ('Bool') { $t->value }
            when ('Nil')  { '#nil' }
            when ('Cons') { sprintf '(%s)' => join ' ' => map { $self->pprint($_) } $self->uncons($t) }
            default {
                die "WTF! $self";
            }
        }
    }

    method DUMP ($t) {
        my $hash = substr($t->hash, 0, 6);
        sprintf(
            '$(%05d) | %-5s | %s | %s | %s',
            $t->index->idx,
            (blessed $t),
            ("\e[38;2;".(join ';' => (hex(substr($hash, 0, 2)), hex(substr($hash, 2, 2)), hex(substr($hash, 4, 2))))."m".$hash."\e[0m"),
            (join ', ' => map {
                blessed $_
                    ? (sprintf '$(%05d)' => $_->idx)
                    : (sprintf '%-18s' => (length $_ > 15 ? (substr($_, 0, 15).'...') : $_))
            } $t->data->@*),
            $self->pprint($t)
        )
    }
}

## -----------------------------------------------------------------------------

class Parser {
    field $alloc  :param :reader;
    field @chars  :reader;
    field @tokens :reader;

    method peek    { $chars[0] }
    method advance { shift @chars }

    method skip_whitespace {
        while (@chars) {
            last if $chars[0] =~ /\S/;
            shift @chars
        }
    }

    method skip_until_newline {
        while (@chars) {
            last if $chars[0] =~ /\n/;
            shift @chars
        }
    }

    method push_stack ($value) { push $tokens[-1]->@* => $value }
    method pop_stack           { pop $tokens[-1]->@* }

    method parse ($source) {
        @tokens = (+[]);
        @chars  = split // => $source;
        while (@chars) {
            $self->find_next_token;
        }
        return pop @tokens;
    }

    method find_next_token {
        my $next = $self->advance;
        given ($next) {
            when (/\s/)    { $self->skip_whitespace }
            when (';')     { $self->skip_until_newline }
            when ('(')     { push @tokens => +[] }
            when (')')     { $self->push_stack( $alloc->List( @{ pop @tokens } ) ) }
            when (/[0-9]/) { $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) ) }
            when ('"')     { $self->push_stack( $alloc->Str( $self->parse_string( $next ) ) ) }
            when ('-')     { $self->peek =~ /[0-9]/
                ? $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) )
                : $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) )
            }
            when ('#') {
                given ($self->peek) {
                    when ('t') { $self->advance; $self->push_stack( $alloc->True ) }
                    when ('f') { $self->advance; $self->push_stack( $alloc->False ) }
                    when ('n') { $self->advance; $self->push_stack( $alloc->Nil ) }
                    default {
                        $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
                    }
                }
            }
            default {
                $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
            }
        }
    }

    method parse_number ($start) {
        $self->peek =~ /[0-9.]/
            ? $self->parse_number( $start . $self->advance )
            : $start;
    }

    method parse_string ($start) {
        if ($self->peek eq '\\') {
            $start .= $self->advance;
            $start .= $self->advance if $self->peek eq '"';
            $self->parse_string( $start );
        } elsif ($self->peek eq '"') {
            $start . $self->advance;
        } else {
            $self->parse_string( $start . $self->advance );
        }
    }

    method parse_symbol ($start) {
        $self->peek !~ /[\s\(\)]/
            ? $self->parse_symbol( $start . $self->advance )
            : $start;
    }
}

## -----------------------------------------------------------------------------

my $a = Allocator->new;
my $p = Parser->new( alloc => $a );

my $exprs = $p->parse(q[


    (defun fact (n)
        (if (== n 0) 1
            (* n (fact (- n 1)))))

    (defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 1)) (fib (- n 2)))))

    (defun tail-call-demo (n)
        (if (== n 0) 0
           (tail-call-demo (- n 1))))

    (defun length (list)
        (if (nil? list) 0
            (+ 1 (length (cdr list)))))

    (defun length-iter (list count)
        (if (nil? list) count
            (length-iter (cdr list) (+ count 1))))

    (defun range (b e)
        (if (== b e)
            (cons e ())
            (cons b (range (+ b 1) e))))

    (defun map (f lst)
        (if (nil? lst) ()
            (cons (f (car lst)) (map f (cdr lst)))))

    (defun grep (f lst)
        (if (nil? lst) ()
            (if (f (car lst))
                (cons (car lst) (grep f (cdr lst)))
                (grep f (cdr lst)))))

    (defun reduce (acc f lst)
        (if (nil? lst) acc
            (reduce (f (car lst) acc) f (cdr lst))))

    (defun sum (lst)
        (reduce 0 (lambda (n acc) (+ acc n)) lst))

    (defun product (lst)
        (reduce 1 (lambda (n acc) (* acc n)) lst))

]);

say 'EXPRS:';
say $a->DUMP($_) foreach @$exprs;

say 'MEMORY:';
say $a->DUMP($_) foreach $a->memory;

## -----------------------------------------------------------------------------
