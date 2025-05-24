#[test_only]
module rwa_platform::carbon_nft_manager_tests {
    // Sui framework imports
    use sui::test_scenario::{Self, Scenario, TransactionEffects, ctx}; // Added ctx here for direct use
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID}; // UID might not be strictly needed if only ID is used
    use sui::transfer::{Self, public_transfer, share_object};
    use sui::table::{Self, Table};
    use sui::display; // For Display objects
    use sui::package::{Self, Publisher}; // For Publisher object
    use sui::types::type_name::type_name; // For type_name! macro

    // Standard library imports
    use std::vector;
    use std::option::{Self, Option};

    // Import the module to be tested and its types
    use rwa_platform::carbon_nft_manager::{
        Self,
        AdminCap,
        VerificationRegistry,
        CarbonCreditNFT,
        EInvalidAmount,
        EVerificationIdAlreadyProcessed,
        is_verification_id_processed, // test-only getter
        // Import NFT getters
        get_nft_amount,
        get_nft_activity_type,
        get_nft_verification_id,
        test_create_admin_cap,       // Assumed to be defined in carbon_nft_manager
        test_create_and_share_registry // Assumed to be defined in carbon_nft_manager
    };

    // === Test Constants ===
    const DEPLOYER: address = @0xA; // Publisher/Admin address
    const USER1: address = @0xB;   // Recipient address
    const VERIFICATION_ID_1: vector<u8> = b"VERIF_001";

    // === Helper Function to Setup Scenario ===
    fun setup_scenario(): (Scenario, ID, ID, ID) {
        let mut scenario = test_scenario::begin(DEPLOYER);
        let scenario_ref = &mut scenario;

        // --- Transaction 1: Manually create initial state (bypass init) ---
        let mut admin_cap_id: ID;
        let mut registry_id: ID;
        let _effects1: TransactionEffects; // Store effects
        {
            let tx_ctx = test_scenario::ctx(scenario_ref);

            // 1. Create and transfer AdminCap using test helper
            let admin_cap = test_create_admin_cap(tx_ctx);
            admin_cap_id = object::id(&admin_cap);
            transfer::public_transfer(admin_cap, DEPLOYER);

            // 2. Create and share Registry using test helper
            registry_id = test_create_and_share_registry(tx_ctx);

            // NOTE: Publisher is NOT taken here
        };
        // Conclude Transaction 1
        _effects1 = test_scenario::next_tx(scenario_ref, DEPLOYER);

        // --- Transaction 2: Take Publisher, retrieve AdminCap, call create_display ---
        let _effects2: TransactionEffects; // Store effects
        {
            // Now in Tx 2, take Publisher created implicitly before Tx 1
            let publisher_obj = test_scenario::take_from_sender<Publisher>(scenario_ref);

            // Retrieve AdminCap that was transferred in Tx 1
            let admin_cap = test_scenario::take_from_sender_by_id<AdminCap>(scenario_ref, admin_cap_id);

            // Call create_display
            let ctx_display = test_scenario::ctx(scenario_ref);
            carbon_nft_manager::create_display(&publisher_obj, ctx_display);

            // Return objects taken in this block
            test_scenario::return_to_sender(scenario_ref, publisher_obj);
            test_scenario::return_to_sender(scenario_ref, admin_cap);
        };
        // Conclude Transaction 2
        _effects2 = test_scenario::next_tx(scenario_ref, DEPLOYER);

        // --- Transaction 3: Retrieve Display ID created in Tx 2 ---
        let display_id: ID;
        {
            // Find the Display object from the effects of Transaction 2
            let mut display_id_opt: Option<ID> = option::none();
            let shared_in_tx2 = test_scenario::shared_objects(&_effects2); // Get shared objects from effects2

            let mut k = 0;
            while (k < vector::length(&shared_in_tx2)) {
                let (id, type_name_val, _is_mutable) = *vector::borrow(&shared_in_tx2, k);
                // Ensure CarbonCreditNFT is imported for type_name! to resolve correctly
                if (type_name_val == type_name!(display::Display<CarbonCreditNFT>)) {
                    display_id_opt = option::some(id);
                    break;
                };
                k = k + 1;
            };
            assert!(option::is_some(&display_id_opt), 200); // Assert Display exists, changed error code
            display_id = option::destroy_some(display_id_opt);
        };
        // Conclude Tx 3 (advancing scenario state for subsequent operations)
        test_scenario::next_tx(scenario_ref, DEPLOYER);

        (scenario, admin_cap_id, registry_id, display_id)
    }

    // === Test Cases ===

    #[test]
    /// Tests that setup creates AdminCap, Registry, and Display
    fun test_init_and_create_display() {
        let (scenario, admin_cap_id, registry_id, display_id) = setup_scenario();
        // Check IDs are not zero (basic check for valid ID)
        assert!(!object::id_is_nil(&admin_cap_id), 100);
        assert!(!object::id_is_nil(&registry_id), 101);
        assert!(!object::id_is_nil(&display_id), 102);
        test_scenario::end(scenario);
    }

    #[test]
    /// Tests successful minting of an NFT.
    fun test_mint_success() {
        let (mut scenario, admin_cap_id, registry_id, _display_id) = setup_scenario();
        let scenario_ref = &mut scenario;
        let mut nft_id: ID; // Declare here

        // --- Transaction 4: Take AdminCap and call mint_nft ---
        let effects4: TransactionEffects;
        {
            let admin_cap = test_scenario::take_from_sender_by_id<AdminCap>(scenario_ref, admin_cap_id);
            let mut registry = test_scenario::take_shared_by_id<VerificationRegistry>(scenario_ref, registry_id);
            let tx_ctx = test_scenario::ctx(scenario_ref);
            carbon_nft_manager::mint_nft(
                &admin_cap,
                &mut registry,
                USER1,
                1000,
                1, // activity_type
                VERIFICATION_ID_1,
                tx_ctx
            );
            assert!(is_verification_id_processed(&registry, VERIFICATION_ID_1), 10);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario_ref, admin_cap);
        };
        effects4 = test_scenario::next_tx(scenario_ref, DEPLOYER);

        // --- Get NFT ID from effects of Tx 4 ---
        // Iterate through objects transferred in effects4 to find the NFT sent to USER1
        let mut found_nft_id = false;
        nft_id = object::id_from_bytes(b""); // Initialize with a dummy ID
        let transferred_objects_in_tx4 = test_scenario::transferred_objects(&effects4); // vector<(ID, address, TypeName)>

        let mut i = 0;
        while (i < vector::length(&transferred_objects_in_tx4)) {
            let (id, recipient, obj_type_name) = *vector::borrow(&transferred_objects_in_tx4, i);
            if (recipient == USER1 && obj_type_name == type_name!(CarbonCreditNFT)) {
                nft_id = id;
                found_nft_id = true;
                break;
            };
            i = i + 1;
        };
        assert!(found_nft_id, 11);

        // --- Transaction 5: USER1 checks inventory ---
        test_scenario::next_tx(scenario_ref, USER1); // Switch context to USER1
        let nft = test_scenario::take_from_address_by_id<CarbonCreditNFT>(scenario_ref, USER1, nft_id);
        assert!(get_nft_amount(&nft) == 1000, 12);
        assert!(get_nft_activity_type(&nft) == 1, 13);
        assert!(get_nft_verification_id(&nft) == VERIFICATION_ID_1, 14);
        test_scenario::return_to_sender(scenario_ref, nft); // USER1 returns the NFT to their own inventory
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = rwa_platform::carbon_nft_manager::EVerificationIdAlreadyProcessed)]
    /// Tests that minting fails if the verification ID has already been used.
    fun test_mint_fail_double_mint() {
        let (mut scenario, admin_cap_id, registry_id, _display_id) = setup_scenario();
        let scenario_ref = &mut scenario;

        // --- Transaction 4: Take AdminCap and mint the first NFT successfully ---
        {
            let admin_cap = test_scenario::take_from_sender_by_id<AdminCap>(scenario_ref, admin_cap_id);
            let mut registry = test_scenario::take_shared_by_id<VerificationRegistry>(scenario_ref, registry_id);
            let tx_ctx = test_scenario::ctx(scenario_ref);
            carbon_nft_manager::mint_nft(&admin_cap, &mut registry, USER1, 1000, 1, VERIFICATION_ID_1, tx_ctx);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario_ref, admin_cap);
        };
        test_scenario::next_tx(scenario_ref, DEPLOYER);

        // --- Transaction 5: Attempt to mint again (should fail) ---
         {
             let admin_cap_again = test_scenario::take_from_sender_by_id<AdminCap>(scenario_ref, admin_cap_id); // Re-take cap
             let mut registry2 = test_scenario::take_shared_by_id<VerificationRegistry>(scenario_ref, registry_id);
             let ctx2 = test_scenario::ctx(scenario_ref);
             carbon_nft_manager::mint_nft(&admin_cap_again, &mut registry2, USER1, 500, 2, VERIFICATION_ID_1, ctx2);
             // This part should abort, so return might not be reached in success path of this block
             test_scenario::return_shared(registry2);
             test_scenario::return_to_sender(scenario_ref, admin_cap_again);
         };
        test_scenario::end(scenario); // This will be reached if the expected failure occurs
    }

    #[test]
    #[expected_failure(abort_code = rwa_platform::carbon_nft_manager::EInvalidAmount)]
    /// Tests that minting fails if amount is zero.
    fun test_mint_fail_zero_amount() {
        let (mut scenario, admin_cap_id, registry_id, _display_id) = setup_scenario();
        let scenario_ref = &mut scenario;

        // --- Transaction 4: Take AdminCap and attempt mint with zero amount (should fail) ---
        {
            let admin_cap = test_scenario::take_from_sender_by_id<AdminCap>(scenario_ref, admin_cap_id);
            let mut registry = test_scenario::take_shared_by_id<VerificationRegistry>(scenario_ref, registry_id);
            let tx_ctx = test_scenario::ctx(scenario_ref);
            carbon_nft_manager::mint_nft(
                &admin_cap,
                &mut registry,
                USER1,
                0, // Zero amount
                1,
                VERIFICATION_ID_1,
                tx_ctx
            );
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario_ref, admin_cap);
        };
        test_scenario::end(scenario);
    }

    #[test]
    /// Tests successful retirement of an NFT.
    fun test_retire_success() {
        let (mut scenario, admin_cap_id, registry_id, _display_id) = setup_scenario();
        let scenario_ref = &mut scenario;
        let mut nft_id: ID; // Declare here

        // --- Transaction 4: Take AdminCap and mint an NFT for USER1 ---
        let effects_mint: TransactionEffects;
        {
            let admin_cap = test_scenario::take_from_sender_by_id<AdminCap>(scenario_ref, admin_cap_id);
            let mut registry = test_scenario::take_shared_by_id<VerificationRegistry>(scenario_ref, registry_id);
            let ctx_mint = test_scenario::ctx(scenario_ref);
            carbon_nft_manager::mint_nft(&admin_cap, &mut registry, USER1, 1000, 1, VERIFICATION_ID_1, ctx_mint);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario_ref, admin_cap);
        };
        effects_mint = test_scenario::next_tx(scenario_ref, DEPLOYER);

        // --- Get minted NFT ID from effects of Tx 4 ---
        let mut found_nft_id = false;
        nft_id = object::id_from_bytes(b""); // Initialize with a dummy ID
        let transferred_objects_in_mint_tx = test_scenario::transferred_objects(&effects_mint);

        let mut i_mint = 0;
        while (i_mint < vector::length(&transferred_objects_in_mint_tx)) {
             let (id_val, recipient_val, obj_type_name_val) = *vector::borrow(&transferred_objects_in_mint_tx, i_mint);
             if (recipient_val == USER1 && obj_type_name_val == type_name!(CarbonCreditNFT)) {
                 nft_id = id_val;
                 found_nft_id = true;
                 break;
             };
             i_mint = i_mint + 1;
        };
        assert!(found_nft_id, 20);

        // --- Transaction 5: USER1 retires the NFT ---
        let effects_retire: TransactionEffects;
        {
            test_scenario::next_tx(scenario_ref, USER1); // Switch context to USER1 for this block
            let nft_to_retire = test_scenario::take_from_address_by_id<CarbonCreditNFT>(scenario_ref, USER1, nft_id);
            let ctx_retire = test_scenario::ctx(scenario_ref);
            carbon_nft_manager::retire_nft(nft_to_retire, ctx_retire);
            // No need to return nft_to_retire as it's consumed (deleted)
        };
        effects_retire = test_scenario::end(scenario); // End scenario as USER1, get final effects

        // --- Check effects for deletion ---
        let deleted_ids = test_scenario::deleted_object_ids(&effects_retire);
        let mut found_deleted = false;
        let mut i_del = 0;
        while(i_del < vector::length(&deleted_ids)) {
            if (*vector::borrow(&deleted_ids, i_del) == nft_id) {
                found_deleted = true;
                break;
            };
            i_del = i_del + 1;
        };
        assert!(found_deleted, 30);
    }
}
