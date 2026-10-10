// Prints pl-box's attraction matrices (from RuleMatrix::from_preset) as f32 bit patterns.
use pl_core::{RuleMatrix, RulePreset};
fn main() {
    for (idx, p) in RulePreset::ALL.iter().enumerate() {
        for k in 1..=16usize {
            let r = std::panic::catch_unwind(|| RuleMatrix::from_preset(*p, k, 12.0..24.0, 33.0..70.0));
            match r {
                Ok(m) => {
                    print!("{} {} {}", idx, p.name(), k);
                    for i in 0..k { for j in 0..k { print!(" {:08x}", m.attraction[i][j].to_bits()); } }
                    println!();
                }
                Err(_) => println!("{} {} {} PANIC", idx, p.name(), k),
            }
        }
    }
}
