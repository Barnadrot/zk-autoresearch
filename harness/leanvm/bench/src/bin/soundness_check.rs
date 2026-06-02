use backend::Air;
use lean_vm::{ALL_TABLES, BusData, BusMultiplicity, TableT};

fn main() {
    let mut all_ok = true;

    for table in &ALL_TABLES {
        let n_committed = table.n_columns();
        let n_total = table.n_columns_total();
        let n_virtual = n_total - n_committed;
        let n_constraints = table.n_constraints();
        let n_shift = table.n_shift_columns();
        let buses = table.bus_interactions();

        let mut bus_virtual_cols = std::collections::BTreeSet::new();
        for bus in &buses {
            if let BusMultiplicity::Column(c) = bus.multiplicity {
                if c >= n_committed {
                    bus_virtual_cols.insert(c);
                }
            }
            if let Some(c) = bus.domainsep.column() {
                if c >= n_committed {
                    bus_virtual_cols.insert(c);
                }
            }
            for d in &bus.data {
                if let Some(c) = d.column() {
                    if c >= n_committed {
                        bus_virtual_cols.insert(c);
                    }
                }
            }
        }

        let n_accounted = bus_virtual_cols.len();
        let n_free = if n_virtual >= n_accounted {
            n_virtual - n_accounted
        } else {
            0
        };

        eprintln!(
            "[soundness] {}: committed={} total={} virtual={} bus_accounted={} free={} constraints={} shift={}",
            table.name(),
            n_committed,
            n_total,
            n_virtual,
            n_accounted,
            n_free,
            n_constraints,
            n_shift,
        );

        if n_free > 0 {
            eprintln!(
                "[soundness] FAIL: {} has {} free virtual columns not bound by bus interactions!",
                table.name(),
                n_free,
            );
            let all_virtual: std::collections::BTreeSet<usize> =
                (n_committed..n_total).collect();
            let unaccounted: Vec<_> = all_virtual.difference(&bus_virtual_cols).collect();
            eprintln!("[soundness]   unaccounted column indices: {:?}", unaccounted);
            all_ok = false;
        }
    }

    if all_ok {
        eprintln!("[soundness] PASS — no free virtual columns in any table.");
    } else {
        eprintln!("[soundness] FAIL — free virtual columns detected!");
        std::process::exit(1);
    }
}
