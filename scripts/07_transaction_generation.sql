USE aml_bank_db;

CREATE TABLE IF NOT EXISTS transaction_generation_jobs (
    job_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    requested_by BIGINT NOT NULL,
    status ENUM('QUEUED', 'RUNNING', 'COMPLETED', 'FAILED')
        NOT NULL DEFAULT 'QUEUED',
    requested_count INT UNSIGNED NOT NULL DEFAULT 1000,
    generated_count INT UNSIGNED NOT NULL DEFAULT 0,
    active_slot TINYINT GENERATED ALWAYS AS (
        CASE WHEN status IN ('QUEUED', 'RUNNING') THEN 1 ELSE NULL END
    ) STORED,
    requested_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    started_at TIMESTAMP(3) NULL,
    finished_at TIMESTAMP(3) NULL,
    error_message TEXT NULL,
    CONSTRAINT chk_generation_job_count CHECK (requested_count = 1000),
    CONSTRAINT chk_generation_progress CHECK (generated_count <= requested_count),
    CONSTRAINT fk_generation_job_officer
        FOREIGN KEY (requested_by)
        REFERENCES compliance_officers(officer_id),
    UNIQUE KEY uq_active_generation_job (active_slot),
    INDEX idx_generation_job_status (status, job_id)
) ENGINE = InnoDB;
