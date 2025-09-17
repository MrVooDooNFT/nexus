//! Proving pipeline that orchestrates the full proving process

use super::engine::ProvingEngine;
use super::input::InputParser;
use super::types::ProverError;
use crate::analytics::track_verification_failed;
use crate::environment::Environment;
use crate::task::Task;
use nexus_sdk::stwo::seq::Proof;
use sha3::{Digest, Keccak256};
use tokio::task::JoinSet;

/// Orchestrates the complete proving pipeline
pub struct ProvingPipeline;

impl ProvingPipeline {
    /// Execute authenticated proving for a task
    pub async fn prove_authenticated(
        task: &Task,
        environment: &Environment,
        client_id: &str,
        per_task_threads: usize,
    ) -> Result<(Vec<Proof>, String, Vec<String>), ProverError> {
        match task.program_id.as_str() {
            "fib_input_initial" => {
                Self::prove_fib_task(task, environment, client_id, per_task_threads).await
            }
            _ => Err(ProverError::MalformedTask(format!(
                "Unsupported program ID: {}",
                task.program_id
            ))),
        }
    }

    /// Process fibonacci proving task with multiple inputs
    async fn prove_fib_task(
        task: &Task,
        environment: &Environment,
        client_id: &str,
        per_task_threads: usize,
    ) -> Result<(Vec<Proof>, String, Vec<String>), ProverError> {
        let all_inputs = task.all_inputs();

        if all_inputs.is_empty() {
            return Err(ProverError::MalformedTask(
                "No inputs provided for task".to_string(),
            ));
        }

        // Sequential fallback when no concurrency requested or only one input
        if per_task_threads <= 1 || all_inputs.len() <= 1 {
            let mut proof_hashes = Vec::new();
            let mut all_proofs: Vec<Proof> = Vec::new();

            for (input_index, input_data) in all_inputs.iter().enumerate() {
                // Step 1: Parse and validate input
                let inputs = InputParser::parse_triple_input(input_data)?;

                // Step 2: Generate and verify proof
                let proof = ProvingEngine::prove_and_validate(&inputs, task, environment, client_id)
                    .await
                    .map_err(|e| match e {
                        ProverError::Stwo(_) | ProverError::GuestProgram(_) => {
                            // Track verification failure
                            let error_msg = format!("Input {}: {}", input_index, e);
                            tokio::spawn(track_verification_failed(
                                task.clone(),
                                error_msg.clone(),
                                environment.clone(),
                                client_id.to_string(),
                            ));
                            e
                        }
                        _ => e,
                    })?;

                // Step 3: Generate proof hash
                let proof_hash = Self::generate_proof_hash(&proof);
                proof_hashes.push(proof_hash);
                all_proofs.push(proof);
            }

            let final_proof_hash = Self::combine_proof_hashes(task, &proof_hashes);
            return Ok((all_proofs, final_proof_hash, proof_hashes));
        }

        // Bounded concurrency path using JoinSet
        let mut join_set = JoinSet::<Result<(usize, Proof, String), ProverError>>::new();
        let max_concurrent = per_task_threads;
        let mut in_flight = 0usize;
        let mut next_index = 0usize;

        // Results storage preserving input order
        let mut proofs_ordered: Vec<Option<Proof>> =
            std::iter::repeat_with(|| None).take(all_inputs.len()).collect();
        let mut proof_hashes_ordered: Vec<Option<String>> =
            std::iter::repeat_with(|| None).take(all_inputs.len()).collect();

        // Prime initial batch
        while next_index < all_inputs.len() && in_flight < max_concurrent {
            Self::enqueue_fib_job(
                &mut join_set,
                task.clone(),
                environment.clone(),
                client_id.to_string(),
                next_index,
                all_inputs[next_index].clone(),
            );
            next_index += 1;
            in_flight += 1;
        }

        // Drain join set, spawning new tasks as others complete
        while in_flight > 0 {
            if let Some(res) = join_set.join_next().await {
                in_flight -= 1;
                let (idx, proof, proof_hash) = res.map_err(|e| ProverError::Io(std::io::Error::new(std::io::ErrorKind::Other, format!("join error: {}", e))))??;
                proofs_ordered[idx] = Some(proof);
                proof_hashes_ordered[idx] = Some(proof_hash);

                if next_index < all_inputs.len() {
                    Self::enqueue_fib_job(
                        &mut join_set,
                        task.clone(),
                        environment.clone(),
                        client_id.to_string(),
                        next_index,
                        all_inputs[next_index].clone(),
                    );
                    next_index += 1;
                    in_flight += 1;
                }
            }
        }

        // Collect ordered results
        let all_proofs: Vec<Proof> = proofs_ordered
            .into_iter()
            .map(|opt| opt.expect("missing proof result for index"))
            .collect();
        let proof_hashes: Vec<String> = proof_hashes_ordered
            .into_iter()
            .map(|opt| opt.expect("missing hash result for index"))
            .collect();

        let final_proof_hash = Self::combine_proof_hashes(task, &proof_hashes);

        Ok((all_proofs, final_proof_hash, proof_hashes))
    }

    fn enqueue_fib_job(
        join_set: &mut JoinSet<Result<(usize, Proof, String), ProverError>>,
        task: Task,
        environment: Environment,
        client_id: String,
        idx: usize,
        input_data: Vec<u8>,
    ) {
        join_set.spawn(async move {
            // Parse input
            let inputs = InputParser::parse_triple_input(&input_data)?;
            // Prove
            let proof = ProvingEngine::prove_and_validate(
                &inputs,
                &task,
                &environment,
                &client_id,
            )
            .await
            .map_err(|e| match e {
                ProverError::Stwo(_) | ProverError::GuestProgram(_) => {
                    // Track verification failure
                    let error_msg = format!("Input {}: {}", idx, e);
                    tokio::spawn(track_verification_failed(
                        task.clone(),
                        error_msg.clone(),
                        environment.clone(),
                        client_id.clone(),
                    ));
                    e
                }
                _ => e,
            })?;
            // Hash
            let proof_hash = ProvingPipeline::generate_proof_hash(&proof);
            Ok::<_, ProverError>((idx, proof, proof_hash))
        });
    }

    /// Generate hash for a proof
    fn generate_proof_hash(proof: &Proof) -> String {
        let proof_bytes = postcard::to_allocvec(proof).expect("Failed to serialize proof");
        format!("{:x}", Keccak256::digest(&proof_bytes))
    }

    /// Combine multiple proof hashes based on task type
    fn combine_proof_hashes(task: &Task, proof_hashes: &[String]) -> String {
        match task.task_type {
            crate::nexus_orchestrator::TaskType::AllProofHashes
            | crate::nexus_orchestrator::TaskType::ProofHash => {
                Task::combine_proof_hashes(proof_hashes)
            }
            _ => proof_hashes.first().cloned().unwrap_or_default(),
        }
    }
}
