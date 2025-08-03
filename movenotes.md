Tx:
- sender
- list/chain of commands
- command inputs
- gas object
- gas price and budget

Pure Arguments
- bool
- uint
- address
- std::string::String // UTF8 string
- std::ascii::String // ASCII string
- vector<T> // where T is a pure type
- std::option::Option<T>
- std::object::ID

let <variable_name>[: <type>]  = <expression>;
let mut <variable_name>[: <type>] = <expression>;

use u64 for everything

add try catches on operations (overflow/underflow guards), because:
- addition aborts if result is too large for the integer type
- subtraction aborts if the result is less than zero
- multiplication aborts if the result is too large for the integer type
- modulus aborts if divisor is 0
- division aborts if the denom is 0

division is truncating division btw

```move
// byte vector literal
let x = b"hello";

// block with an empty expression, however, the compiler will
// insert an empty expression automatically: `let none = { () }`
// let none = {};

// block with let statements and an expression.
let sum = {
    let a = 1;
    let b = 2;
    a + b // last expression is the value of the block
};

// ternary
if (bool_expression) something1 else something2;

while (bool_expression) { expr; };

loop { expr; break };
```

Structs are to sui as interfaces are to typescript
- struct definitions must be comma separated

```move
let mut artist = Artist {
    name: b"The Beatles".to_string()
};
```

```move
// Access the `name` field of the `Artist` struct.
let artist_name = artist.name;

// Access a field of the `Artist` struct.
assert!(artist.name == b"The Beatles".to_string());

// Mutate the `name` field of the `Artist` struct.
artist.name = b"Led Zeppelin".to_string();

// Check that the `name` field has been mutated.
assert!(artist.name == b"Led Zeppelin".to_string());

// unpacking a struct
// Unpack the `Artist` struct and create a new variable `name`
// with the value of the `name` field.
let Artist { name } = artist;

// Unpack the `Artist` struct and ignore the `name` field.
let Artist { name: _ } = artist;
```

Struct abilities
- copy
- drop
- key
- store

Modules

```
// File: sources/module_one.move
module book::module_one;

/// Struct defined in the same module.
public struct Character has drop {}

/// Simple function that creates a new `Character` instance.
public fun new(): Character { Character {} }
```

```
// File: sources/module_two.move
module book::module_two;

use book::module_one; // importing module_one from the same package

/// Calls the `new` function from the `module_one` module.
public fun create_and_ignore() {
    let _ = module_one::new();
}
```

diff function

vectors

```move
// An empty vector of bool elements.
let empty: vector<bool> = vector[];

// A vector of u8 elements.
let v: vector<u8> = vector[10, 20, 30];

// A vector of vector<u8> elements.
let vv: vector<vector<u8>> = vector[
    vector[10, 20],
    vector[30, 40]
];
```

Vector operations:
- push_back
- pop_back
- length
- is_empty
- remove

Options

```move
// `option::some` creates an `Option` value with a value.
let mut opt = option::some(b"Alice");

// `option::none` creates an `Option` without a value. We need to specify the
// type since it can't be inferred from context.
let empty : Option<u64> = option::none();

// `option.is_some()` returns true if option contains a value.
assert!(opt.is_some());
assert!(empty.is_none());

// internal value can be `borrow`ed and `borrow_mut`ed.
assert!(opt.borrow() == &b"Alice");

// `option.extract` takes the value out of the option, leaving the option empty.
let inner = opt.extract();

// `option.is_none()` returns true if option is None.
assert!(opt.is_none());
```

use string not ascii

```move
// the module is `std::string` and the type is `String`
use std::string::{Self, String};

// strings are normally created using the `utf8` function
// type declaration is not necessary, we put it here for clarity
let hello: String = string::utf8(b"Hello");

// The `.to_string()` alias on the `vector<u8>` is more convenient
let hello = b"Hello".to_string();
```

so basically strings are

```move
let stringvar = b"I'm a string!".to_string()
```

conditionals

```move

if (x > 0) {
    expression
};


#[test]
fun test_if_else() {
    let x = 5;
    let y = if (x > 0) {
        1
    } else {
        0
    };

    assert!(y == 1);
}
```

usually while is used when the number of iterations is known in advance, and loop is used when the number of iterations is not known in advance or there are multiple exit points.

```move

#[test]
fun test_break_loop() {
    let mut x = 0;

    // This will loop until `x` is 5.
    loop {
        x = x + 1;

        // If `x` is 5, then exit the loop.
        if (x == 5) {
            break // Exit the loop.
        }
    };

    assert!(x == 5);
}

```

```move
#[test]
fun test_continue_loop() {
    let mut x = 0;

    // This will loop until `x` is 10.
    loop {
        x = x + 1;

        // If `x` is odd, then skip the rest of the iteration.
        if (x % 2 == 1) {
            continue // Skip the rest of the iteration.
        };

        std::debug::print(&x);

        // If `x` is 10, then exit the loop.
        if (x == 10) {
            break // Exit the loop.
        }
    };

    assert!(x == 10); // 10
}
```

```
// define a "config" module that exports the constants

module book::config;

const ITEM_PRICE: u64 = 100;
const TAX_RATE: u64 = 10;
const SHIPPING_COST: u64 = 5;

/// Returns the price of an item.
public fun item_price(): u64 { ITEM_PRICE }
/// Returns the tax rate.
public fun tax_rate(): u64 { TAX_RATE }
/// Returns the shipping cost.
public fun shipping_cost(): u64 { SHIPPING_COST }
```

```move

module book::package_visibility;

public(package) fun package_only() { /* ... */ }

```

