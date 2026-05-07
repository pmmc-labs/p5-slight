;; -----------------------------------------------------------------------------
;; meta-circular LISP interpreter
;; -----------------------------------------------------------------------------
;; - derived from LISP from Nothing by Nils Holm
;; -----------------------------------------------------------------------------

;; find value of x in e
(lookup
    (lambda (x e)
        (cond ((eq? nil e       ) nil)
              ((eq? x   (caar e)) (cadar e))
              (true (lookup x (cdr e))))))

;; evaluate cond
(evcon
    (lambda (c e)
        (cond ((xeval (caar c) e) (xeval (cadar c) e))
              (t (evcon (cdr c) e)))))

;; bind variables v to arguments a in e
(bind
    (lambda (v a e)
        (cond ((eq v nil) e)
              (t (cons (cons (car v)
                    (cons (xeval (car a) e)
                        nil))
                 (bind (cdr v) (cdr a) e))))))

;; same as append
(append2
    (lambda (a b)
        (cond ((eq a nil) b)
            (t (cons (car a)
                    (append2 (cdr a) b))))))

;; evaluate expression x in environment e
(xeval
    (lambda (x e)
        (cond
            ((eq x t) t)
            ((atom x)
                (lookup x e))
            ((atom (car x))
                (cond
                    ((eq (car x) (quote quote))
                        (cadr x))
                    ((eq (car x) (quote atom))
                        (atom (xeval (cadr x) e)))
                    ((eq (car x) (quote eq))
                        (eq (xeval (cadr x) e)
                            (xeval (caddr x) e)))
                    ((eq (car x) (quote car))
                        (car (xeval (cadr x) e)))
                    ((eq (car x) (quote cdr))
                        (cdr (xeval (cadr x) e)))
                    ((eq (car x) (quote caar))
                        (caar (xeval (cadr x) e)))
                    ((eq (car x) (quote cadr))
                        (cadr (xeval (cadr x) e)))
                    ((eq (car x) (quote cdar))
                        (cdar (xeval (cadr x) e)))
                    ((eq (car x) (quote cadar))
                        (cadar (xeval (cadr x) e)))
                    ((eq (car x) (quote caddr))
                        (caddr (xeval (cadr x) e)))
                    ((eq (car x) (quote cons))
                        (cons (xeval (cadr x) e)
                              (xeval (caddr x) e)))
                    ((eq (car x) (quote cond))
                        (evcon (cdr x) e))
                    ((eq (car x) (quote label))
                        (xeval (caddr x)
                               (append2 (cadr x) e)))
                    ((eq nil (car x))
                        (quote *undefined))
                    ((eq (car x) (quote lambda))
                        x)
                    (t (xeval (cons (xeval (car x) e) (cdr x)) e))
                    ))
            ((eq (caar x) (quote lambda))
                (xeval (cadr (cdar x))
                       (bind (cadar x) (cdr x) e)))
        )))


(xeval (quote form) nil)




