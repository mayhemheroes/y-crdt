#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: Vec<&[u8]>| {
    let mut data = data;
    data.retain(|d| d.len() > 8);
    let _ = yrs::merge_updates_v1(&data);
});
