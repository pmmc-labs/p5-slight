;; -----------------------------------------------------------------------------
;; meta-circular LISP interpreter
;; -----------------------------------------------------------------------------
;; - derived from LISP from Nothing by Nils Holm
;; -----------------------------------------------------------------------------

;; find value of x in e
(define mc-lookup (x e)
        (cond ((eq? nil e       ) nil)
              ((eq? x   (caar e)) (cadar e))
               (true (mc-lookup x (cdr e)))))

;; evaluate cond
(define mc-cond (c e)
        (cond ((mc-eval (caar c) e) (mc-eval (cadar c) e))
               (true (mc-cond (cdr c) e))))

;; bind variables v to arguments a in e
(define mc-bind (v a e)
        (cond ((eq? v nil) e)
               (true (cons (cons (car v)
                     (cons (mc-eval (car a) e)
                      nil))
                 (mc-bind (cdr v) (cdr a) e)))))

;; same as append
(define mc-append (a b)
        (cond ((eq? a nil) b)
               (t (cons (car a)
                    (mc-append (cdr a) b)))))

;; evaluate expression x in environment e
(define mc-eval (x e)
        (cond
            ((eq? x t) t)
            ((atom? x)
                (mc-lookup x e))
            ((atom? (car x))
                (cond
                    ((eq? (car x) (quote quote))
                        (cadr x))
                    ((eq? (car x) (quote atom?))
                        (atom? (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote eq?))
                        (eq? (mc-eval (cadr  x) e)
                             (mc-eval (caddr x) e)))
                    ((eq? (car x) (quote car))
                        (car (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote cdr))
                        (cdr (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote caar))
                        (caar (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote cadr))
                        (cadr (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote cdar))
                        (cdar (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote cadar))
                        (cadar (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote caddr))
                        (caddr (mc-eval (cadr x) e)))
                    ((eq? (car x) (quote cons))
                        (cons (mc-eval (cadr x) e)
                              (mc-eval (caddr x) e)))
                    ((eq? (car x) (quote cond))
                        (mc-cond (cdr x) e))
                    ((eq? (car x) (quote label))
                        (mc-eval (caddr x)
                               (mc-append (cadr x) e)))
                    ((eq? nil (car x))
                        (quote *undefined))
                    ((eq? (car x) (quote lambda))
                        x)
                    (true (mc-eval (cons (mc-eval (car x) e) (cdr x)) e))
                    ))
            ((eq? (caar x) (quote lambda))
                (mc-eval (cadr (cdar x))
                       (mc-bind (cadar x) (cdr x) e)))
        ))


(mc-eval (quote form) nil)




