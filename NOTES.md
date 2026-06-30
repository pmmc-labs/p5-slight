<!----------------------------------------------------------------------------->
# NOTES
<!----------------------------------------------------------------------------->

## Parsing & Compiling

```
$(00003) | Str | b4ee4e | BEFORE BIF CREATION| BEFORE BIF CREATION
$(00076) | Str | 660323 | BEFORE PARSING     | BEFORE PARSING
$(00580) | Str | 967074 | BEFORE COMPILING   | BEFORE COMPILING
$(00845) ...
```

- 504 for parsing
- 265 during compilation

## AST Runtime

```
$(00845) | Str | 381104 | BEFORE AST RUNTIME | BEFORE AST RUNTIME
$(02082) | Str | 619679 | THE END            | THE END
```
- 1237 at runtime

## CEK Runtime

```
$(00845) | Str | 31f80d | BEFORE CEK RUNTIME | BEFORE CEK RUNTIME
$(02361) | Str | 619679 | THE END            | THE END
```

- 1516 at runtime
