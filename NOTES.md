<!----------------------------------------------------------------------------->
# NOTES
<!----------------------------------------------------------------------------->

## make a prelude ...

```
(defun map (f l)
    (if (nil? l)
        ()
        (list (f (car l)) (map f (cdr l)))))

(defun length (l)
    (if (nil? l) 0
        (+ 1 (length (cdr l)))))


```

# commit ideas

```
;; local commits inside an actor
;; would look like this and commit
;; to the local working memory
(commit :message "Adding Bob and Chris stuff"
    (patch
        (assert! Bob   :knows    Alice )
        (assert! Bob   :knows    Chris )
        (assert! Chris :knows    Bob   )
        (assert! Chris :works-w/ Alice )
        (assert! Chris :knows    Alice )))


;; local queries

(let mutuals
    (where? (x)
        (and (x :knows Alice)
             (x :knows Chris))))

;; patches from other actors are sent
;; as merge requests messages
(send PID (merge-request
    :author     (getpid)
    :description "Adding Alice stuff"
    (patch
        (assert! Alice :knows    Bob   )
        (assert! Alice :knows    Chris )
        (assert! Alice :works-w/ Chris )
        (retract Chris :knows    Bob   ))))

```

<!----------------------------------------------------------------------------->

# FACT:
# input    0 1 2 3  4   5   6    7     8      9      10       11
# expected 1 1 2 6 24 120 720 5040 40320 362880 3628800 39916800

# FIB:
# input    0 1 2 3 4 5 6  7  8  9 10 11
# expected 0 1 1 2 3 5 8 13 21 34 55 89


<!----------------------------------------------------------------------------->

```
┌─────┬─────┬─────┬─────┬─────┬─────┐
│░▓░░▓│░░░░░│░░░░░│░░░░░│░░░░░│░░░░░│
├─────┼─────┼─────┼─────┼─────┼─────┤
│░░░░░│░░░░░│░▓░░░│███░░│░░░░░│░░░░░│
├─────┼─────┼─────┼─────┼─────┼─────┤
│░▓░░▓│░░███│▓░▓▓░│░░░░░│░░░░░│░░░░░│
├─────┼─────┼─────┼─────┼─────┼─────┤
│▓░▓░▓│░▓░░▓│░▓░░▓│░░▓██│░░░░░│░░░░░│
├─────┼─────┼─────┼─────┼─────┼─────┤
│░░░░░│░░░░░│░░░░░│░░░▓█│░░░░░│░░░░░│
├─────┼─────┼─────┼─────┼─────┼─────┤
│░░░░░│░░░░░│░░░░░│░░░░░│░░░░░│░░░░░│
├─────┼─────┼─────┼─────┼─────┼─────┤
│░░░░░│░░░░░│░░░░░│░░░░░│░░░░░│░░░░░│
└─────┴─────┴─────┴─────┴─────┴─────┘

╱╳╳╳╳╳╱
         ▄   
    ▁▁▁▁╱ ╲
  ▁╱    ╲  ╲
 ╱ ╲    ╱╲  ╲
1  "2" 3  4  5

╭╴          ╶╮
│ 0, 1, 2, 3 │
╰╴          ╶╯

─┬──┬──┬──┬──┐
 0  1  2  3  ◌
 
│┄ 0
│┄ 1
│┄ 2 
│┄ 3
◌    
 
   ╱╲ 
  0 ╱╲
   1 ╱╲
    2 ╱╲  
     3  ◌
        
╲┄ 0
 ╲┄ 1
  ╲┄ 2 
   ╲┄ 3
    ◌         
            
░░░

◧◨

◩◪

◢◣
◥◤
▼▶▲◀

◳◰◲◳
```

<!----------------------------------------------------------------------------->

```
## -----------------------------------------------------------------------------

class Channel {
    field @write;
    field @read;

    method can_read { !! scalar @read }

    method read ($size=1) {
        my @buffer;
        while ($size--) {
            push @buffer => shift @read;
            last unless @read;
        }
        return @buffer;
    }

    method write (@terms) { push @write => @terms; return; }

    method flush {
        push @read => @write;
        @write = ();
        return $self->can_read;
    }

    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

## -----------------------------------------------------------------------------

class TTY::Reader {
    field $fh :param :reader = \*STDIN;
    method read ($size=1) {
        my @buffer;
        push @buffer => $fh->readline while $size--;
        return @buffer;
    }
    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

class TTY::Writer {
    field $fh :param :reader = \*STDOUT;
    method write (@terms) { print $fh @terms }
    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

class TTY::Logger {
    field $fh :param :reader = \*STDERR;
    method write (@terms) { warn $fh @terms, "\n" }
    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}

class TTY::Channel :isa(Channel) {
    field $reader :param :reader;
    field $writer :param :reader;
    method can_read { true }
    method read ($size=undef) {
        my @read = $reader->read(defined $size ? $size->raw : );
        return Cons->of( map { Str->new(raw => $_) } @read )
    }
    method flush {
        $writer->write( map $_->to_string, @write );
        @write = ();
        return true;
    }
    ADJUST { $::ALLOCATIONS{MISC}->{ blessed $self }++ }
}
```

