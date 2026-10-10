// Runs pl-box's spawn layouts (Simulation::spawn_*) from a fixed fastrand
// seed and prints, per case, the particle count, an FNV-1a hash over every
// (x bits, y bits, kind) in order, and the first particle.
use pl_core::Simulation;
type F = fn(usize, usize, f32, f32) -> Vec<pl_core::Particle>;
fn main() {
    let layouts: [(&str, F); 16] = [
        ("pie", Simulation::spawn_pie),
        ("line", Simulation::spawn_line),
        ("ring", Simulation::spawn_ring),
        ("rainbow_ring", Simulation::spawn_rainbow_ring),
        ("rainbow_rings", Simulation::spawn_rainbow_rings),
        ("soft_clusters", Simulation::spawn_soft_clusters),
        ("radiant_fans", Simulation::spawn_radiant_fans),
        ("spiral", Simulation::spawn_spiral),
        ("twin_spirals", Simulation::spawn_twin_spirals),
        ("spiral_arms", Simulation::spawn_spiral_arms),
        ("blocks", Simulation::spawn_blocks),
        ("line_mixed", Simulation::spawn_line_mixed),
        ("stripes", Simulation::spawn_stripes),
        ("polar_maze", Simulation::spawn_polar_maze),
        ("heart", Simulation::spawn_heart),
        ("star", Simulation::spawn_star),
    ];
    let sizes = [(2000usize, 1600.0f32, 900.0f32), (1001, 900.0, 1400.0)];
    let mut case = 0u64;
    for (li, (name, f)) in layouts.iter().enumerate() {
        for k in [2usize, 3, 5, 8, 13, 16] {
            for &(n, w, h) in &sizes {
                let seed = 0x5eed_0000 + case;
                case += 1;
                fastrand::seed(seed);
                let p = f(n, k, w, h);
                let mut hsh: u64 = 0xcbf29ce484222325;
                let mut mix = |v: u32| {
                    for b in v.to_le_bytes() {
                        hsh ^= b as u64;
                        hsh = hsh.wrapping_mul(0x100000001b3);
                    }
                };
                for q in &p {
                    mix(q.position.x.to_bits());
                    mix(q.position.y.to_bits());
                    mix(q.kind as u32);
                }
                let (x0, y0, t0) = p.first().map(|q| (q.position.x, q.position.y, q.kind)).unwrap_or((0.0, 0.0, 0));
                println!("{} {} {} {} {} {} {} {} {:016x} {:08x} {:08x} {}",
                    li, name, n, k, w, h, seed, p.len(), hsh, x0.to_bits(), y0.to_bits(), t0);
            }
        }
    }
}
