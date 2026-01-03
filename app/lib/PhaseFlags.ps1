enum OperationFlags {
    # — None
    None = 0

    # ───── Fault-Tolerance
    Retryable = 1                             # 1<<0: retry on transient failure

    # ───── Concurrency Control
    RequiresLock = 4                          # 1<<2: enforce exclusive operation lock
    SkipIfLocked = 8                          # 1<<3: skip operation if lock is already held

    # ───── Execution Control
    DryRun             = 32                  # 1<<5: simulate operation without side effects
    Force              = 64                  # 1<<6: override safety protections
    RollbackOnFailure  = 128                 # 1<<7: trigger rollback if Run phase fails

    # ───── User Interaction
    ConfirmBeforeAction = 512                # 1<<9: prompt user before critical actions

    # ───── Logging / Severity
    LogVerbose   = 2048                      # 1<<11: detailed log output
    LogSilent    = 4096                      # 1<<12: suppress all logging
    WarnOnError  = 8192                      # 1<<13: convert any failure into a warning

    # ───── Error Outcome Strategy
    SucceedOnError    = 32768                # 1<<15: treat any error or undefined block as success
    PropagateOnError  = 65536                # 1<<16: on error → inherit prior phase result

    # ───── Reserved (preserve bit gaps between categories)
    Reserved_FaultTolerance   = 2            # 1<<1
    Reserved_Concurrency      = 16           # 1<<4
    Reserved_Execution        = 256          # 1<<8
    Reserved_Interaction      = 1024         # 1<<10
    Reserved_Logging          = 16384        # 1<<14
    Reserved_Future           = 131072       # 1<<17
}
