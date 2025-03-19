# Servicer Investor Reporting (SIR) System

A comprehensive system for managing and reporting on mortgage loan pools, designed to meet Fannie Mae's investor reporting requirements.

## Overview

The SIR system handles the following key functions:

1. Monthly loan pool reporting
2. Delinquency tracking and reporting
3. Loan payoff processing
4. Pool factor calculations
5. Exception tracking and reporting

## System Components

### Database Schema

The system uses Oracle Database with the following core tables:

- `pool_definition`: Stores pool-level information
- `loan_master`: Contains loan-level details
- `pool_loan_xref`: Maps loans to pools
- `monthly_remittance`: Tracks monthly remittance data
- `loan_payment_history`: Records loan payment transactions
- `exception_log`: Logs system exceptions and issues

### PL/SQL Packages

- `investor_reporting_pkg`: Core package containing business logic for:
  - Processing monthly remittances
  - Generating reports
  - Calculating pool statistics
  - Processing loan payoffs
  - Exception handling

### Shell Scripts

1. `monthly_reporting.sh`: Main script for monthly reporting process
   - Processes all active pools
   - Generates monthly reports
   - Creates exception reports
   - Produces pool summaries

2. `process_delinquent_loans.sh`: Handles delinquent loan processing
   - Updates delinquency status
   - Generates delinquency reports
   - Creates alerts for severe cases

3. `process_payoffs.sh`: Processes loan payoffs
   - Handles loan liquidations
   - Updates pool statistics
   - Generates payoff reports

## Setup and Configuration

### Prerequisites

- Oracle Database 19c or later
- Oracle SQL*Plus client
- Bash shell environment
- Required environment variables:
  - `ORACLE_PASSWORD`
  - `ORACLE_SID`
  - `ORACLE_HOME`

### Directory Structure

```
/var/
├── log/
│   └── sir/           # Log files
└── reports/
    └── sir/           # Report output
        ├── delinquency/
        └── payoffs/
```

### Installation

1. Create the database schema:
   ```bash
   sqlplus system/password@database @sql/schema/tables.sql
   ```

2. Install the PL/SQL packages:
   ```bash
   sqlplus sir_user/password@database @sql/packages/investor_reporting_pkg.sql
   ```

3. Set up required directories:
   ```bash
   mkdir -p /var/log/sir
   mkdir -p /var/reports/sir/{delinquency,payoffs}
   chmod 755 /var/log/sir /var/reports/sir
   ```

## Usage

### Monthly Reporting

Run the monthly reporting process:
```bash
./scripts/monthly_reporting.sh
```

### Delinquency Processing

Process delinquent loans:
```bash
./scripts/process_delinquent_loans.sh
```

### Payoff Processing

Process loan payoffs (requires input file):
```bash
./scripts/process_payoffs.sh payoff_data.csv
```

The payoff input file should be a CSV with the following format:
```csv
loan_id,payoff_date,payoff_amount,payoff_type
123456,2024-03-15,250000.00,VOLUNTARY
```

## Monitoring and Maintenance

### Log Files

- Monthly reporting logs: `/var/log/sir/monthly_report_*.log`
- Delinquency processing logs: `/var/log/sir/delinquency_report_*.log`
- Payoff processing logs: `/var/log/sir/payoff_processing_*.log`

### Reports

- Pool summary reports: `/var/reports/sir/pool_summary_*.txt`
- Exception reports: `/var/reports/sir/exception_report_*.txt`
- Delinquency reports: `/var/reports/sir/delinquency/delinquency_report_*.txt`
- Payoff reports: `/var/reports/sir/payoffs/payoff_report_*.txt`

### Maintenance Tasks

1. Monitor log files for errors
2. Review exception reports daily
3. Archive old reports (automated after 12 months)
4. Verify database backups
5. Monitor disk space for report storage

## Error Handling

The system includes comprehensive error handling:

1. All operations are logged
2. Critical errors trigger alerts
3. Transactions are properly rolled back on failure
4. Exceptions are tracked in the database
5. Email notifications for critical issues (configurable)

## Security Considerations

1. Database credentials are managed via environment variables
2. Sensitive data is not logged
3. File permissions are restricted
4. Database roles and privileges are properly segregated
5. Audit logging is enabled for critical operations

## Support and Contact

For system support, contact:
- Email: support@example.com
- Phone: (555) 123-4567

## License

Copyright © 2024. All rights reserved. 