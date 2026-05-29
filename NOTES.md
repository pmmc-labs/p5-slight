
```

(defun dbms (db) (do
    (let msg (recv))
    
    (let op   (car msg))
    (let args (cdr msg))
    
    (if (eq? op 'Query?)
        (do ...)
    (if (eq? op 'Assert!))
        (do ...)
    (throw '(UNHANDLED msg)))
    
    (yield (dbms db))))


;; data 
(db ! '(Assert!  :Bob    :has-first-name  "Robert"      ))
(db ! '(Assert!  :Bob    :has-last-name   "Smith"       ))
(db ! '(Assert!  :Bob    :has-age         50            ))
(db ! '(Assert!  :Alice  :has-first-name  "Allison"     ))
(db ! '(Assert!  :Alice  :has-last-name   "Chains"      ))
(db ! '(Assert!  :Alice  :has-age         40            ))
(db ! '(Assert!  :Chris  :has-first-name  "Christopher" ))
(db ! '(Assert!  :Chris  :has-last-name   "Cross"       ))
(db ! '(Assert!  :Chris  :has-age         60            ))

;; relations
(db ! '(Assert!  :Bob    :knows?       :Alice)) 
(db ! '(Assert!  :Bob    :knows?       :Chris)) 
(db ! '(Assert!  :Chris  :knows?       :Bob)) 
(db ! '(Assert!  :Alice  :knows?       :Bob)) 
(db ! '(Assert!  :Alice  :knows?       :Chris)) 
(db ! '(Assert!  :Alice  :works-with?  :Chris)) 
(db ! '(Assert!  :Chris  :works-with?  :Alice)) 



(db ! '(Query? :_ :has-first-name "Robert"))


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
