# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest as builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src

RUN echo building instrumented harnesses && \
    bash -c "pushd yrs/fuzz && cargo +nightly -Z sparse-registry fuzz build && popd" && \
    mv yrs/fuzz/target/x86_64-unknown-linux-gnu/release/merge_v1 /merge_v1 && \
    mv yrs/fuzz/target/x86_64-unknown-linux-gnu/release/merge_v2 /merge_v2 && \
    echo done

RUN echo building non-instrumented harnesses && \
    export RUSTFLAGS="--cfg fuzzing -Clink-dead-code -Cdebug-assertions -C codegen-units=1" && \
    bash -c "pushd yrs/fuzz && cargo +nightly -Z sparse-registry build --release && popd" && \
    mv yrs/fuzz/target/release/merge_v1 /merge_v1_no_inst && \
    mv yrs/fuzz/target/release/merge_v2 /merge_v2_no_inst && \
    echo done

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /merge_v1 /merge_v1_no_inst /
COPY --from=builder /merge_v2 /merge_v2_no_inst /
