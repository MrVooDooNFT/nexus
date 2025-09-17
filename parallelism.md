## Intra-task paralellik ve eşzamanlılık değişiklikleri

Bu not, CLI’de yaptığımız paralelleştirme ve oran sınırlama (rate limiting) iyileştirmelerini özetler. Yeni yaklaşım, dış paralellik (worker sayısı) ile tek görev içi paralelliği (intra-task) birbirinden ayırarak 429 hatalarını azaltırken toplam throughput’u artırmayı hedefler.

### Yeni CLI bayrağı

- `--per-task-threads N`: Tek bir görev içindeki `public_inputs_list` girdilerinin en fazla N tanesini aynı anda ispatlar (intra-task concurrency).
- `--max-threads` (DEPRECATED): Artık dikkate alınmaz. Paralellik görev içinden (`--per-task-threads`) yönetilir.
- Varsayılan: `per-task-threads = 1`.

### Kullanım önerisi

- Rate limit’i (≈2 dk pencere) tetiklememek için dış worker paralelliği devre dışıdır; yalnızca `--per-task-threads` ayarlanır.
- Belleğe göre artırın. 64 GB RAM için 6–8 genelde güvenli başlangıç.

### Bellek notları

- Koddaki 4 GB/proof projeksiyonu muhafazakârdır. Gerçek kullanım zorluğa göre değişir (SMALL görevlerde ~1 GB/proof gözlemlenebilir).
- Yaklaşık bellek: `aktif_worker × per-task-threads × proof_belleği`.
- OOM (Out Of Memory) belirtileri: ani kill, çıkış kodu 137. Gerekirse `--per-task-threads` veya `--max-threads` azaltın.

### Uygulama detayları (dosya/diff seviyesinde)

- `clients/cli/src/prover/pipeline.rs`

  - `ProvingPipeline::prove_authenticated(..., per_task_threads)` imzası eklendi.
  - `prove_fib_task` içinde sıralı çalışmadan, `tokio::task::JoinSet` ile sınırlı eşzamanlılığa (bounded concurrency) geçirildi.
  - `per_task_threads <= 1` veya `Task size == 1` durumunda sıralı moda otomatik geçiş yapar.

- `clients/cli/src/workers/prover.rs`

  - `TaskProver` artık `WorkerConfig.per_task_threads` değerini `ProvingPipeline`’a aktarır.

- `clients/cli/src/workers/core.rs`

  - `WorkerConfig`’a `per_task_threads: usize` alanı eklendi (varsayılan 1).

- `clients/cli/src/main.rs`

  - `Start` komutuna `--per-task-threads N` bayrağı eklendi.
  - `start(...)` fonksiyonu `per_task_threads` parametresi alacak şekilde güncellendi ve `setup_session(...)`’a iletiliyor.

- `clients/cli/src/session/setup.rs`

  - `setup_session(...)` `per_task_threads` alıp `start_authenticated_workers(...)`’a geçirir.

- `clients/cli/src/runtime.rs`

  - `start_authenticated_workers(...)` `per_task_threads` parametresi alır ve `WorkerConfig`’a uygular.
  - Birden fazla worker başlatılırken her worker’a başlangıç jitter’ı verilerek ilk fetch denemeleri zamana yayıldı.

- `clients/cli/src/workers/authenticated_worker.rs`

  - `startup_jitter: Duration` alanı eklendi. Worker başlatıldığında ilk fetch öncesi kısa bekleme ile senkron patlamalar azaltıldı.

- `clients/cli/src/network/request_timer.rs`

  - `RequestTimer::with_jitter(max_ms)` eklendi. Sunucunun `Retry-After` veya lokal gecikmelerine küçük rastgele jitter ekler.
  - `record_success`/`record_failure` yolları jitter ile çeşitlendirildi.

- `clients/cli/src/workers/fetcher.rs` ve `clients/cli/src/workers/submitter.rs`
  - `RequestTimer::with_jitter(...)` kullanımı eklendi (fetch için ~7.5s, submit için ~2s). Amaç eşzamanlı yeniden denemeleri dağıtmak.

### Oran sınırlaması (rate limiting) ile uyum

- Fetch tarafında en az 2 dakikalık pencere ve sunucunun `Retry-After` değerine uyum korunur.
- Jitter ve başlangıç beklemesi sayesinde eşzamanlı yeniden denemeler dağıtılır.
- Dış paralellik devre dışı olduğundan, throughput `--per-task-threads` ile ölçeklenir.

### Geriye dönük etki ve taşınabilirlik

- `--max-threads` DEPRECATED ve yok sayılır.
- `--per-task-threads` kullanılmazsa varsayılan 1 olarak kalır.
- Kütüphane API’si (Prover SDK) değişmedi; yalnızca pipeline çağrı akışı ve concurrency kontrolü güncellendi.

### Örnek komutlar

```bash
# Headless, 6 intra-task thread, Large üst sınırı
./target/release/nexus-network start \
  --headless --node-id 36116773 \
  --per-task-threads 6 \
  --max-difficulty LARGE

# TUI, 4 intra-task thread
./target/release/nexus-network start \
  --node-id 36116773 \
  --per-task-threads 4
```

### Hızlı doğrulama checklist’i (yeni sürüm geldiğinde yeniden uygulamak için)

1. `--per-task-threads` bayrağı `clients/cli/src/main.rs` içinde mevcut mı ve `start(...)` → `setup_session(...)` → `start_authenticated_workers(...)` zincirinde iletiliyor mu?
2. `WorkerConfig` içinde `per_task_threads` alanı var mı ve `TaskProver` bunu `ProvingPipeline::prove_authenticated(..., per_task_threads)` ile kullanıyor mu?
3. `ProvingPipeline` bounded concurrency kullanıyor mu (JoinSet) ve sıralı fallback’ı var mı?
4. `AuthenticatedWorker` başlangıç jitter’ı içeriyor mu?
5. `RequestTimer` jitter destekliyor mu ve fetch/submit terimleri bu jitter’ı kullanıyor mu?
6. Derleme/lint temiz mi; örnek komutlar çalışıyor mu?
