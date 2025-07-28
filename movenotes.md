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

