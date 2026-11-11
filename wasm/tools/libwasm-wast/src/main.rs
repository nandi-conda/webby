//! Runs WebAssembly spec test scripts (.wast) on Ladybird's LibWasm engine, one store per script, and prints a line
//! per script: `<path>: <passed> passed, <failed> failed, <skipped> skipped`, after the failures (at most
//! `WAST_MAX_FAILURES`, default 20, per script). It exits with 1 if anything failed.
//!
//! The same source builds natively, against either interpreter backend (LIBWASM_INTERPRETER_BACKEND=c), and for
//! wasm32-wasip1, so that their results can be compared. Directives this runner does not model (threads, the
//! component model, stack switching) count as skipped.

use libwasm_engine::runtime::{ExternValue, InstanceAddress, Store, Trap, Value};
use libwasm_engine::types::{
    AddressType, FuncType, GlobalType, HeapType, Limits, MemoryType, RefType, TableType, ValType,
};
use std::collections::HashMap;
use std::sync::Arc;
use wast::core::{NanPattern, V128Pattern, WastArgCore, WastRetCore};
use wast::parser::{self, ParseBuffer};
use wast::{QuoteWat, Wast, WastArg, WastDirective, WastExecute, WastInvoke, WastRet};

type Exports = HashMap<String, ExternValue>;

struct Runner {
    store: Store,
    registered: HashMap<String, Exports>,
    named: HashMap<String, InstanceAddress>,
    current: Option<InstanceAddress>,
    passed: usize,
    failed: usize,
    skipped: usize,
    failures: Vec<String>,
}

/// A host reference for `ref.extern n`: tag 2 marks host references, the low bit i31 ones.
fn extern_reference(n: u32) -> u64 {
    ((u64::from(n) + 1) << 2) | 2
}

fn spectest(store: &mut Store) -> Exports {
    let mut exports = Exports::new();
    let print = |store: &mut Store, params: Vec<ValType>| {
        ExternValue::Function(store.allocate_host_function(
            FuncType { params, results: vec![] },
            std::rc::Rc::new(|_: &mut Store, _: &[Value]| Ok(vec![])),
        ))
    };
    use ValType::{F32, F64, I32, I64};
    for (name, params) in [
        ("print", vec![]),
        ("print_i32", vec![I32]),
        ("print_i64", vec![I64]),
        ("print_f32", vec![F32]),
        ("print_f64", vec![F64]),
        ("print_i32_f32", vec![I32, F32]),
        ("print_f64_f64", vec![F64, F64]),
    ] {
        let function = print(store, params);
        exports.insert(name.to_string(), function);
    }
    for (name, ty, value) in [
        ("global_i32", I32, Value::I32(666)),
        ("global_i64", I64, Value::I64(666)),
        ("global_f32", F32, Value::F32(666.6f32.to_bits())),
        ("global_f64", F64, Value::F64(666.6f64.to_bits())),
    ] {
        let global = store.allocate_global(GlobalType { value: ty, mutable: false }, value);
        exports.insert(name.to_string(), ExternValue::Global(global));
    }
    let limits = |min, max, address_type| Limits {
        min,
        max: Some(max),
        address_type,
        shared: false,
    };
    if let Some(table) = store.allocate_table(
        TableType {
            element: RefType::FUNCREF,
            limits: limits(10, 20, AddressType::I32),
        },
        0,
    ) {
        exports.insert("table".to_string(), ExternValue::Table(table));
    }
    if let Some(table) = store.allocate_table(
        TableType {
            element: RefType::FUNCREF,
            limits: limits(10, 20, AddressType::I64),
        },
        0,
    ) {
        exports.insert("table64".to_string(), ExternValue::Table(table));
    }
    if let Some(memory) = store.allocate_memory(MemoryType {
        limits: limits(1, 2, AddressType::I32),
    }) {
        exports.insert("memory".to_string(), ExternValue::Memory(memory));
    }
    if let Some(memory) = store.allocate_memory(MemoryType {
        limits: Limits {
            shared: true,
            ..limits(1, 2, AddressType::I32)
        },
    }) {
        exports.insert("shared_memory".to_string(), ExternValue::Memory(memory));
    }
    exports
}

enum Outcome {
    Values(Vec<Value>),
    Trap(Trap),
    /// The script is wrong or uses something this runner does not model.
    Error(String),
}

impl Runner {
    fn new() -> Self {
        let mut store = Store::new();
        let spectest = spectest(&mut store);
        Self {
            store,
            registered: HashMap::from([("spectest".to_string(), spectest)]),
            named: HashMap::new(),
            current: None,
            passed: 0,
            failed: 0,
            skipped: 0,
            failures: Vec::new(),
        }
    }

    fn pass(&mut self) {
        self.passed += 1;
    }

    fn fail(&mut self, line: usize, message: String) {
        self.failed += 1;
        self.failures.push(format!("line {line}: {message}"));
    }

    fn instance(&self, id: Option<wast::token::Id<'_>>) -> Option<InstanceAddress> {
        match id {
            Some(id) => self.named.get(id.name()).copied(),
            None => self.current,
        }
    }

    /// Compile and instantiate a module, resolving its imports from the registered instances.
    fn instantiate(&mut self, bytes: &[u8]) -> Result<InstanceAddress, String> {
        let module = libwasm_engine::compile(bytes).map_err(|error| format!("compile: {error:?}"))?;
        let mut imports = Vec::with_capacity(module.imports.len());
        for import in &module.imports {
            let value = self
                .registered
                .get(&import.module)
                .and_then(|exports| exports.get(&import.name))
                .ok_or_else(|| format!("unknown import {}.{}", import.module, import.name))?;
            imports.push(*value);
        }
        self.store
            .instantiate(Arc::new(module), &imports)
            .map_err(|error| format!("instantiate: {error:?}"))
    }

    fn argument(&self, argument: &WastArg<'_>) -> Option<Value> {
        let WastArg::Core(argument) = argument else {
            return None;
        };
        Some(match argument {
            WastArgCore::I32(value) => Value::I32(*value),
            WastArgCore::I64(value) => Value::I64(*value),
            WastArgCore::F32(value) => Value::F32(value.bits),
            WastArgCore::F64(value) => Value::F64(value.bits),
            WastArgCore::V128(value) => Value::V128(u128::from_le_bytes(value.to_le_bytes())),
            WastArgCore::RefNull(_) => Value::Ref(0),
            WastArgCore::RefExtern(n) => Value::Ref(extern_reference(*n)),
            WastArgCore::RefHost(n) => Value::Ref(extern_reference(*n)),
        })
    }

    fn invoke(&mut self, invoke: &WastInvoke<'_>) -> Outcome {
        let Some(instance) = self.instance(invoke.module) else {
            return Outcome::Error("no such instance".to_string());
        };
        let Some(ExternValue::Function(function)) = self.store.instance(instance).export(invoke.name) else {
            return Outcome::Error(format!("no function export {}", invoke.name));
        };
        let mut arguments = Vec::new();
        for argument in &invoke.args {
            match self.argument(argument) {
                Some(value) => arguments.push(value),
                None => return Outcome::Error("unsupported argument".to_string()),
            }
        }
        match self.store.invoke(function, &arguments) {
            Ok(values) => Outcome::Values(values),
            Err(trap) => Outcome::Trap(trap),
        }
    }

    fn execute(&mut self, execute: &mut WastExecute<'_>) -> Outcome {
        match execute {
            WastExecute::Invoke(invoke) => self.invoke(invoke),
            WastExecute::Wat(wat) => {
                let bytes = match wat.encode() {
                    Ok(bytes) => bytes,
                    Err(error) => return Outcome::Error(format!("encode: {error}")),
                };
                match self.instantiate(&bytes) {
                    Ok(_) => Outcome::Values(vec![]),
                    Err(error) if error.starts_with("instantiate: Trap") => {
                        Outcome::Trap(Trap::Host(error))
                    }
                    Err(error) => Outcome::Error(error),
                }
            }
            WastExecute::Get { module, global, .. } => {
                let Some(instance) = self.instance(*module) else {
                    return Outcome::Error("no such instance".to_string());
                };
                match self.store.instance(instance).export(global) {
                    Some(ExternValue::Global(address)) => Outcome::Values(vec![self.store.global(address).get()]),
                    _ => Outcome::Error(format!("no global export {global}")),
                }
            }
        }
    }

    fn module(&mut self, line: usize, wat: &mut QuoteWat<'_>) {
        let name = wat.name().map(|id| id.name().to_string());
        let bytes = match wat.encode() {
            Ok(bytes) => bytes,
            Err(error) => {
                self.skipped += 1;
                let _ = error;
                return;
            }
        };
        match self.instantiate(&bytes) {
            Ok(instance) => {
                self.current = Some(instance);
                if let Some(name) = name {
                    self.named.insert(name, instance);
                }
                self.pass();
            }
            Err(error) => {
                self.current = None;
                self.fail(line, format!("module: {error}"));
            }
        }
    }

    fn directive(&mut self, line: usize, directive: WastDirective<'_>) {
        match directive {
            WastDirective::Module(mut wat) => self.module(line, &mut wat),
            WastDirective::Register { name, module, .. } => {
                let Some(instance) = self.instance(module) else {
                    self.fail(line, "register: no such instance".to_string());
                    return;
                };
                let exports = self.store.instance(instance).exports.clone();
                self.registered.insert(name.to_string(), exports);
            }
            WastDirective::Invoke(invoke) => match self.invoke(&invoke) {
                Outcome::Values(_) => self.pass(),
                Outcome::Trap(trap) => self.fail(line, format!("invoke {} trapped: {trap:?}", invoke.name)),
                Outcome::Error(error) => self.fail(line, error),
            },
            WastDirective::AssertReturn {
                mut exec, results, ..
            } => match self.execute(&mut exec) {
                Outcome::Values(values) => {
                    if values.len() == results.len()
                        && values.iter().zip(&results).all(|(value, expected)| self.matches(*value, expected))
                    {
                        self.pass();
                    } else {
                        self.fail(line, format!("returned {values:x?}, expected {results:?}"));
                    }
                }
                Outcome::Trap(trap) => self.fail(line, format!("trapped: {trap:?}")),
                Outcome::Error(error) => self.fail(line, error),
            },
            WastDirective::AssertTrap { mut exec, message, .. } => match self.execute(&mut exec) {
                Outcome::Trap(_) => self.pass(),
                Outcome::Values(values) => self.fail(line, format!("returned {values:x?}, expected trap {message}")),
                Outcome::Error(error) => self.fail(line, error),
            },
            WastDirective::AssertExhaustion { call, message, .. } => match self.invoke(&call) {
                Outcome::Trap(_) => self.pass(),
                Outcome::Values(values) => self.fail(line, format!("returned {values:x?}, expected {message}")),
                Outcome::Error(error) => self.fail(line, error),
            },
            WastDirective::AssertException { mut exec, .. } => match self.execute(&mut exec) {
                Outcome::Trap(Trap::UncaughtException(_)) => self.pass(),
                Outcome::Trap(trap) => self.fail(line, format!("trapped {trap:?}, expected an exception")),
                Outcome::Values(values) => self.fail(line, format!("returned {values:x?}, expected an exception")),
                Outcome::Error(error) => self.fail(line, error),
            },
            WastDirective::AssertInvalid { mut module, .. } | WastDirective::AssertMalformed { mut module, .. } => {
                match module.encode() {
                    // The text itself is malformed, which is the parser's business, not the engine's.
                    Err(_) => self.skipped += 1,
                    Ok(bytes) => match libwasm_engine::compile(&bytes) {
                        Err(_) => self.pass(),
                        Ok(_) => self.fail(line, "module should not validate".to_string()),
                    },
                }
            }
            WastDirective::AssertUnlinkable { mut module, .. } => match module.encode() {
                Err(_) => self.skipped += 1,
                Ok(bytes) => match self.instantiate(&bytes) {
                    Err(_) => self.pass(),
                    Ok(_) => self.fail(line, "module should not link".to_string()),
                },
            },
            _ => self.skipped += 1,
        }
    }

    fn matches(&self, value: Value, expected: &WastRet<'_>) -> bool {
        let WastRet::Core(expected) = expected else {
            return false;
        };
        self.matches_core(value, expected)
    }

    fn matches_core(&self, value: Value, expected: &WastRetCore<'_>) -> bool {
        match (value, expected) {
            (Value::I32(value), WastRetCore::I32(expected)) => value == *expected,
            (Value::I64(value), WastRetCore::I64(expected)) => value == *expected,
            (Value::F32(bits), WastRetCore::F32(expected)) => f32_matches(bits, expected),
            (Value::F64(bits), WastRetCore::F64(expected)) => f64_matches(bits, expected),
            (Value::V128(bits), WastRetCore::V128(expected)) => v128_matches(bits, expected),
            (Value::Ref(bits), WastRetCore::RefNull(_)) => bits == 0,
            (Value::Ref(bits), WastRetCore::RefExtern(None)) => bits != 0,
            (Value::Ref(bits), WastRetCore::RefExtern(Some(n))) => bits == extern_reference(*n),
            (Value::Ref(bits), WastRetCore::RefHost(n)) => bits == extern_reference(*n),
            (Value::Ref(bits), WastRetCore::RefFunc(_)) => bits != 0,
            (Value::Ref(bits), WastRetCore::RefAny) => bits != 0,
            (Value::Ref(bits), WastRetCore::RefEq) => bits != 0 && self.store.reference_matches(bits, HeapType::Eq),
            (Value::Ref(bits), WastRetCore::RefI31) => bits & 1 != 0,
            (Value::Ref(bits), WastRetCore::RefStruct) => {
                bits != 0 && self.store.reference_matches(bits, HeapType::Struct)
            }
            (Value::Ref(bits), WastRetCore::RefArray) => {
                bits != 0 && self.store.reference_matches(bits, HeapType::Array)
            }
            (value, WastRetCore::Either(options)) => options.iter().any(|option| self.matches_core(value, option)),
            _ => false,
        }
    }
}

fn f32_matches(bits: u32, expected: &NanPattern<wast::token::F32>) -> bool {
    match expected {
        NanPattern::CanonicalNan => bits & 0x7fff_ffff == 0x7fc0_0000,
        NanPattern::ArithmeticNan => bits & 0x7fc0_0000 == 0x7fc0_0000,
        NanPattern::Value(value) => bits == value.bits,
    }
}

fn f64_matches(bits: u64, expected: &NanPattern<wast::token::F64>) -> bool {
    match expected {
        NanPattern::CanonicalNan => bits & 0x7fff_ffff_ffff_ffff == 0x7ff8_0000_0000_0000,
        NanPattern::ArithmeticNan => bits & 0x7ff8_0000_0000_0000 == 0x7ff8_0000_0000_0000,
        NanPattern::Value(value) => bits == value.bits,
    }
}

fn v128_matches(bits: u128, expected: &V128Pattern) -> bool {
    let bytes = bits.to_le_bytes();
    match expected {
        V128Pattern::I8x16(lanes) => lanes.iter().enumerate().all(|(i, lane)| bytes[i] == *lane as u8),
        V128Pattern::I16x8(lanes) => lanes
            .iter()
            .enumerate()
            .all(|(i, lane)| u16::from_le_bytes([bytes[2 * i], bytes[2 * i + 1]]) == *lane as u16),
        V128Pattern::I32x4(lanes) => lanes
            .iter()
            .enumerate()
            .all(|(i, lane)| u32::from_le_bytes(bytes[4 * i..4 * i + 4].try_into().unwrap()) == *lane as u32),
        V128Pattern::I64x2(lanes) => lanes
            .iter()
            .enumerate()
            .all(|(i, lane)| u64::from_le_bytes(bytes[8 * i..8 * i + 8].try_into().unwrap()) == *lane as u64),
        V128Pattern::F32x4(lanes) => lanes.iter().enumerate().all(|(i, lane)| {
            f32_matches(u32::from_le_bytes(bytes[4 * i..4 * i + 4].try_into().unwrap()), lane)
        }),
        V128Pattern::F64x2(lanes) => lanes.iter().enumerate().all(|(i, lane)| {
            f64_matches(u64::from_le_bytes(bytes[8 * i..8 * i + 8].try_into().unwrap()), lane)
        }),
    }
}

fn run(path: &str, max_failures: usize) -> bool {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) => {
            println!("{path}: cannot read: {error}");
            return false;
        }
    };
    let buffer = match ParseBuffer::new(&text) {
        Ok(buffer) => buffer,
        Err(error) => {
            println!("{path}: cannot lex: {error}");
            return false;
        }
    };
    let wast = match parser::parse::<Wast>(&buffer) {
        Ok(wast) => wast,
        Err(error) => {
            println!("{path}: cannot parse: {error}");
            return false;
        }
    };
    let mut runner = Runner::new();
    for directive in wast.directives {
        let (line, _) = directive.span().linecol_in(&text);
        runner.directive(line + 1, directive);
    }
    for failure in runner.failures.iter().take(max_failures) {
        println!("{path}: {failure}");
    }
    println!(
        "{path}: {} passed, {} failed, {} skipped",
        runner.passed, runner.failed, runner.skipped
    );
    runner.failed == 0
}

fn main() {
    let max_failures = std::env::var("WAST_MAX_FAILURES")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(20);
    let mut ok = true;
    for path in std::env::args().skip(1) {
        ok &= run(&path, max_failures);
    }
    std::process::exit(if ok { 0 } else { 1 });
}
