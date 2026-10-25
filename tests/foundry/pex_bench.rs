//! JKU's PEX bench (iic-jku/open-pdks-regression-tests, `<pdk>/pex_bench/`):
//! metal-only layouts, each isolating one parasitic term, whose expected
//! values are the PDK extraction deck's arithmetic done by hand.
//!
//! Oracle: the bench's `expected/results.json`, its `deck` rows for tables
//! A to E, held to the bench's own 0.05 % (`scripts/check_results.py`):
//! - A, capacitance to substrate: the ground capacitance of the nets
//!   `plate` and `wire` of `capsub_<layer>`;
//! - B, overlap: the coupling between `bot` and `top` of
//!   `overlap_<lower>_<upper>`;
//! - C, sidewall: the coupling between `a` and `b` of `sidewall_m1_s<s>`;
//! - D, sheet resistance: the point-to-point resistance of `res_<layer>`
//!   between its labels `l` and `r`;
//! - E, n cuts in parallel: `vc_*` (or IHP's `vp_*`) between `l` and `u`,
//!   less the one-cut chain's metal, as the bench's `analyse.py` takes it:
//!   R(n) − R(1) + Rvia. The `n1` rows hold by construction and are not
//!   compared.
//!
//! The bench's coefficients are Magic's tech file, the shipped decks' are
//! their own sources: a row where they part is ledgered `differs` in
//! `docs/xcheck/pex_bench.tsv`, with the reason, and must keep differing;
//! `agrees` must keep agreeing. Every compared row has one ledger row.

use gpurify::engine::p2p;
use gpurify::engine::pipeline::{Extracted, Inputs, Loaded};
use gpurify::engine::run::{run, Checks, RunOptions, StageStatus};
use gpurify::extract::{Parasitic, ParasiticNetwork};
use gpurify::geom::Dbu;
use gpurify_testgen::oracle;
use std::collections::BTreeMap;
use std::path::Path;

/// The bench's tolerance for deck arithmetic (`check_results.py` `TOL`).
const TOL: f64 = 5e-4;

/// The bench's PDK directory, the shipped deck, and what the deck lacks to
/// read the bench: IHP's LVS deck takes net names from the `.text` purpose
/// (25) only, the bench labels its ports on `.pin` (2).
const PDKS: &[(&str, &str, &str)] = &[
    ("sky130A", "pdks/sky130.deck", ""),
    ("gf180mcuD", "pdks/gf180mcu.deck", ""),
    (
        "ihp-sg13g2",
        "pdks/ihp_sg13g2.deck",
        "connect label metal1_pin names metal1\n\
         layer bench_metal2_pin = gds(10, 2)\nconnect label bench_metal2_pin names metal2\n\
         layer bench_metal3_pin = gds(30, 2)\nconnect label bench_metal3_pin names metal3\n\
         layer bench_metal4_pin = gds(50, 2)\nconnect label bench_metal4_pin names metal4\n\
         layer bench_metal5_pin = gds(67, 2)\nconnect label bench_metal5_pin names metal5\n\
         layer bench_topmetal1_pin = gds(126, 2)\nconnect label bench_topmetal1_pin names topmetal1\n\
         layer bench_topmetal2_pin = gds(134, 2)\nconnect label bench_topmetal2_pin names topmetal2\n",
    ),
];

/// One PEX run of a bench cell.
struct Cell {
    loaded: Loaded,
    extracted: Extracted,
    network: ParasiticNetwork,
}

impl Cell {
    fn ground_ff(&self, name: &str) -> Result<f64, String> {
        let pieces = self
            .loaded
            .strings
            .get(name)
            .map_or(&[][..], |id| self.extracted.ports.nets_of(id));
        let [net] = *pieces else {
            return Err(format!("{name} names {} nets", pieces.len()));
        };
        let n = &self.network;
        Ok((0..n.element_count())
            .filter_map(|i| match n.value[i] {
                Parasitic::GroundCap(c) if n.node_net[n.from[i].0 as usize] == net => Some(c.raw()),
                _ => None,
            })
            .fold(0.0, |a, c| a + c))
    }

    fn coupling_ff(&self, a: &str, b: &str) -> Result<f64, String> {
        p2p::coupling(&self.loaded, &self.extracted, &self.network, a, b)
    }

    /// The resistance between the labels `a` and `b`, which name one net.
    fn ohms(&self, a: &str, b: &str) -> Result<f64, String> {
        let at = |name: &str| -> Result<(Dbu, Dbu), String> {
            let id = self
                .loaded
                .strings
                .get(name)
                .ok_or(format!("no label {name}"))?;
            let l = self
                .loaded
                .provenance
                .placed()
                .iter()
                .find(|l| l.name == id)
                .ok_or(format!("no label {name}"))?;
            Ok((l.at.x, l.at.y))
        };
        let pairs = p2p::resistance(&self.loaded, &self.extracted, a, &[at(a)?, at(b)?])?;
        pairs
            .first()
            .map(|&(_, _, r)| r)
            .ok_or(format!("{a} and {b} are not joined"))
    }
}

fn pex(gds: &Path, deck: &Path) -> Result<Cell, String> {
    let options = RunOptions {
        checks: Checks {
            pex: true,
            ..Checks::default()
        },
        quasistatic_nets: if std::env::var_os("BENCH_QS").is_some() {
            let name = gds.file_stem().unwrap().to_str().unwrap();
            let nets: &[&str] = if name.starts_with("capsub") {
                &["plate", "wire"]
            } else if name.starts_with("overlap") {
                &["bot", "top"]
            } else if name.starts_with("sidewall") {
                &["a", "b"]
            } else {
                &[]
            };
            nets.iter().map(|&n| n.to_owned()).collect()
        } else {
            Vec::new()
        },
        ..RunOptions::default()
    };
    let inputs = Inputs {
        layout: gds.to_path_buf(),
        deck: deck.to_path_buf(),
        ..Inputs::default()
    };
    let (loaded, extracted, outputs, summary) =
        run(&inputs, &options).map_err(|e| e.to_string())?;
    if summary.pex != StageStatus::Ran {
        return Err(format!("PEX {:?}", summary.pex));
    }
    let network = outputs.parasitics.ok_or("no network")?;
    Ok(Cell {
        loaded,
        extracted,
        network,
    })
}

/// The bench cell `name`, run once.
fn run_cell<'a>(
    cells: &'a mut BTreeMap<String, Result<Cell, String>>,
    layout: &Path,
    deck: &Path,
    name: &str,
) -> Result<&'a Cell, String> {
    cells
        .entry(name.to_owned())
        .or_insert_with(|| pex(&layout.join(format!("{name}.gds")), deck))
        .as_ref()
        .map_err(|e| format!("{name}: {e}"))
}

/// Ours for one `deck` row of the bench, or why there is none.
fn ours(
    table: &str,
    key: &str,
    layout: &Path,
    deck: &Path,
    want: &BTreeMap<(String, String), f64>,
    cells: &mut BTreeMap<String, Result<Cell, String>>,
) -> Result<f64, String> {
    match table {
        "A" => {
            let (layer, net) = key.rsplit_once('_').ok_or("key")?;
            run_cell(cells, layout, deck, &format!("capsub_{layer}"))?.ground_ff(net)
        }
        "B" => {
            let (up, lo) = key.split_once("_over_").ok_or("key")?;
            run_cell(cells, layout, deck, &format!("overlap_{lo}_{up}"))?.coupling_ff("bot", "top")
        }
        "C" => run_cell(cells, layout, deck, &format!("sidewall_m1_{key}"))?.coupling_ff("a", "b"),
        "D" => run_cell(cells, layout, deck, &format!("res_{key}"))?.ohms("l", "r"),
        "E" => {
            let (level, _) = key.rsplit_once("_n").ok_or("key")?;
            let family = if layout.join(format!("vp_{level}_n1.gds")).exists() {
                "vp"
            } else {
                "vc"
            };
            let one =
                run_cell(cells, layout, deck, &format!("{family}_{level}_n1"))?.ohms("l", "u")?;
            let n = run_cell(cells, layout, deck, &format!("{family}_{key}"))?.ohms("l", "u")?;
            let rvia = want[&("E".to_owned(), format!("{level}_n1"))];
            Ok(n - one + rvia)
        }
        _ => Err(format!("table {table}")),
    }
}

/// Oracle: JKU's PEX bench, its hand-computed `deck` values for tables A
/// to E (module doc), row by row of `docs/xcheck/pex_bench.tsv`.
#[test]
#[ignore = "release tier: needs the pinned JKU bench checkout (tests/foundry/pdks.tsv)"]
fn jku_pex_bench() {
    let bench = crate::checkout("jku_regression");
    let ledger_path = "docs/xcheck/pex_bench.tsv";
    let text = std::fs::read_to_string(crate::repo().join(ledger_path)).expect("the ledger");
    let mut ledger: BTreeMap<(String, String, String), (String, usize)> = BTreeMap::new();
    for (i, line) in text.lines().enumerate() {
        if line.starts_with('#') || line.trim().is_empty() || line.starts_with("pdk\t") {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        assert!(f.len() == 5, "{ledger_path}:{}: five columns", i + 1);
        assert!(
            matches!(f[3], "agrees" | "differs"),
            "{ledger_path}:{}: status {}",
            i + 1,
            f[3]
        );
        let key = (f[0].to_owned(), f[1].to_owned(), f[2].to_owned());
        let dup = ledger.insert(key, (f[3].to_owned(), i + 1));
        assert!(dup.is_none(), "{ledger_path}:{}: a second row", i + 1);
    }

    let mut problems = Vec::new();
    for &(pdk, deck, shim) in PDKS {
        let dir = bench.join(pdk).join("pex_bench");
        let layout = crate::need(&dir, "layout");
        let json =
            std::fs::read_to_string(crate::need(&dir, "expected/results.json")).expect("read");
        let rows: Vec<serde_json::Value> = serde_json::from_str(&json).expect("the bench's JSON");
        let want: BTreeMap<(String, String), f64> = rows
            .iter()
            .filter(|r| {
                r["source"] == "deck" && "ABCDE".contains(r["table"].as_str().unwrap_or("-"))
            })
            .map(|r| {
                let s = |k: &str| r[k].as_str().expect("a string").to_owned();
                (
                    (s("table"), s("key")),
                    r["value"].as_f64().expect("a number"),
                )
            })
            .collect();
        assert!(!want.is_empty(), "{pdk}: no deck rows");
        let scratch = oracle::scratch(&format!("pex-bench-{pdk}"));
        let deck_path = scratch.join("bench.deck");
        let text = std::fs::read_to_string(crate::repo().join(deck)).expect("the shipped deck");
        std::fs::write(&deck_path, format!("{text}\n{shim}")).expect("writable");

        let mut cells = BTreeMap::new();
        println!("{pdk}:");
        for ((table, key), &value) in &want {
            if table == "E" && key.ends_with("_n1") {
                continue;
            }
            let name = format!("{pdk} {table} {key}");
            let got = ours(table, key, &layout, &deck_path, &want, &mut cells);
            let rel = got.as_ref().map(|g| (g - value).abs() / value.abs());
            match &got {
                Ok(g) => println!(
                    "  {table} {key:<16} want {value:>12.4} ours {g:>12.4} {:>+8.2}%",
                    (g - value) / value * 100.0
                ),
                Err(e) => println!("  {table} {key:<16} want {value:>12.4} ours -- {e}"),
            }
            let Some((status, line)) = ledger.remove(&(pdk.to_owned(), table.clone(), key.clone()))
            else {
                problems.push(format!("{name}: no ledger row"));
                continue;
            };
            let at = format!("{ledger_path}:{line} {name}");
            match (status.as_str(), rel) {
                (_, Err(e)) => problems.push(format!("{at}: did not run: {e}")),
                ("agrees", Ok(r)) if r > TOL => {
                    problems.push(format!("{at}: marked agrees, off by {:.3} %", r * 100.0));
                }
                ("differs", Ok(r)) if r <= TOL => {
                    problems.push(format!("{at}: marked differs, but agrees"));
                }
                _ => {}
            }
        }
        let _ = std::fs::remove_dir_all(&scratch);
    }
    problems.extend(ledger.iter().map(|((p, t, k), (_, line))| {
        format!("{ledger_path}:{line} {p} {t} {k}: the bench has no such row")
    }));
    assert!(
        problems.is_empty(),
        "{} problems:\n{}",
        problems.len(),
        problems.join("\n")
    );
}
