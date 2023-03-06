module wormhole::upgrade_contract {
    use sui::tx_context::{TxContext};

    use wormhole::bytes32::{Self, Bytes32};
    use wormhole::cursor::{Self};
    use wormhole::governance_message::{Self, GovernanceMessage};
    use wormhole::state::{Self, State};

    // NOTE: This exists to mock up sui::package for proposed upgrades.
    use wormhole::dummy_sui_package::{UpgradeReceipt, UpgradeTicket};

    const E_DIGEST_ZERO_BYTES: u64 = 0;

    /// Specific governance payload ID (action) to complete upgrading the
    /// contract.
    const ACTION_UPGRADE_CONTRACT: u8 = 1;

    struct UpgradeContract {
        digest: Bytes32
    }

    /// Issue an `UpgradeTicket` for the upgrade given a contract upgrade VAA.
    public fun upgrade_contract(
        wormhole_state: &mut State,
        vaa_buf: vector<u8>,
        ctx: &TxContext
    ): UpgradeTicket {
        let msg =
            governance_message::parse_and_verify_vaa(
                wormhole_state,
                vaa_buf,
                ctx
            );

        // Do not allow this VAA to be replayed.
        state::consume_vaa_hash(
            wormhole_state,
            governance_message::vaa_hash(&msg)
        );

        // Proceed with processing new implementation version.
        handle_upgrade_contract(wormhole_state, msg)
    }

    /// Finalize the upgrade that ran to produce the given `receipt`. This
    /// method invokes `state::commit_upgrade` which interacts with
    /// `sui::package`.
    public fun commit_upgrade(
        self: &mut State,
        receipt: UpgradeReceipt,
    ) {
        state::commit_upgrade(self, receipt)
    }

    fun handle_upgrade_contract(
        wormhole_state: &mut State,
        msg: GovernanceMessage
    ): UpgradeTicket {
        // Verify that this governance message is to update the Wormhole fee.
        let governance_payload =
            governance_message::take_local_action(
                msg,
                state::governance_module(),
                ACTION_UPGRADE_CONTRACT
            );

        // Deserialize the payload as amount to change the Wormhole fee.
        let UpgradeContract { digest } = deserialize(governance_payload);

        state::authorize_upgrade(wormhole_state, digest)
    }

    fun deserialize(payload: vector<u8>): UpgradeContract {
        let cur = cursor::new(payload);

        // This amount cannot be greater than max u64.
        let digest = bytes32::take(&mut cur);
        assert!(bytes32::is_nonzero(&digest), E_DIGEST_ZERO_BYTES);

        cursor::destroy_empty(cur);

        UpgradeContract { digest }
    }

    #[test_only]
    public fun action(): u8 {
        ACTION_UPGRADE_CONTRACT
    }
}

#[test_only]
module wormhole::upgrade_contract_test {
    // TODO
}
