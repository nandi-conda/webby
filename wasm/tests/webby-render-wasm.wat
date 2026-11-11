(module
  (memory (export "memory") 1)
  ;; Sum of squares 0..n-1, through memory: each square is stored, then all are loaded and added.
  (func (export "squares") (param $n i32) (result i32) (local $i i32) (local $sum i32)
    (block $done (loop $store
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (i32.store (i32.shl (local.get $i) (i32.const 2)) (i32.mul (local.get $i) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $store)))
    (local.set $i (i32.const 0))
    (block $done (loop $load
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $sum (i32.add (local.get $sum) (i32.load (i32.shl (local.get $i) (i32.const 2)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $load)))
    (local.get $sum))
  (func (export "grow") (param i32) (result i32) (memory.grow (local.get 0)))
  (func (export "load") (param i32) (result i32) (i32.load8_u (local.get 0)))
  ;; i32x4 lanes [1,2,3,4] * [5,6,7,8] summed: 70.
  (func (export "dot") (result i32) (local $v v128)
    (local.set $v (i32x4.mul (v128.const i32x4 1 2 3 4) (v128.const i32x4 5 6 7 8)))
    (i32.add (i32.add (i32x4.extract_lane 0 (local.get $v)) (i32x4.extract_lane 1 (local.get $v)))
             (i32.add (i32x4.extract_lane 2 (local.get $v)) (i32x4.extract_lane 3 (local.get $v)))))
  (func $fib (export "fib") (param $n i64) (result i64)
    (if (result i64) (i64.lt_u (local.get $n) (i64.const 2)) (then (local.get $n))
      (else (i64.add (call $fib (i64.sub (local.get $n) (i64.const 1))) (call $fib (i64.sub (local.get $n) (i64.const 2))))))))
