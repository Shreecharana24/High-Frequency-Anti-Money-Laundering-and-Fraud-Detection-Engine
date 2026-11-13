USE aml_bank_db;

CREATE TABLE IF NOT EXISTS compliance_officer_accounts (
    account_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    officer_id BIGINT NOT NULL UNIQUE,
    email VARCHAR(254) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    failed_login_attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,
    locked_until TIMESTAMP(3) NULL,
    created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),
    CONSTRAINT fk_officer_account_officer
        FOREIGN KEY (officer_id)
        REFERENCES compliance_officers(officer_id)
        ON DELETE CASCADE
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS compliance_officer_sessions (
    session_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    officer_id BIGINT NOT NULL,
    token_hash CHAR(64) NOT NULL UNIQUE,
    created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    expires_at TIMESTAMP(3) NOT NULL,
    revoked_at TIMESTAMP(3) NULL,
    CONSTRAINT fk_officer_session_officer
        FOREIGN KEY (officer_id)
        REFERENCES compliance_officers(officer_id)
        ON DELETE CASCADE,
    INDEX idx_officer_session_lookup (officer_id, expires_at, revoked_at)
) ENGINE = InnoDB;
