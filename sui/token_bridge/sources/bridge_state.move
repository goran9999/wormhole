module token_bridge::bridge_state {
   use std::option::{Self, Option};

   use sui::object::{Self, UID};
   use sui::vec_map::{Self, VecMap};
   use sui::tx_context::{TxContext};
   use sui::coin::{Coin};
   use sui::transfer::{Self};
   use sui::tx_context::{Self};
   use sui::sui::SUI;

   use token_bridge::treasury::{Self, CoinStore, TreasuryCapStore};
   use token_bridge::string32::{String32};
   use token_bridge::dynamic_set;

   use wormhole::external_address::{ExternalAddress};
   use wormhole::myu16::{U16};
   use wormhole::wormhole::{Self};
   use wormhole::state::{State};
   use wormhole::emitter::{EmitterCapability};
   use wormhole::set::{Self, Set};

   const E_IS_NOT_WRAPPED_ASSET: u64 = 0;
   const E_IS_NOT_REGISTERED_NATIVE_ASSET: u64 = 1;

   friend token_bridge::vaa;
   friend token_bridge::register_chain;
   friend token_bridge::wrapped;
   friend token_bridge::complete_transfer;
   friend token_bridge::transfer_tokens;
   #[test_only]
   friend token_bridge::test_bridge_state;
   #[test_only]
   friend token_bridge::token_bridge_vaa_test;

   /// Capability for creating a bridge state object, granted to sender when this
   /// module is deployed
   struct DeployerCapability has key, store {id: UID}

   /// WrappedAssetInfo is a Sui object (has key ability) that functions as a Value
   /// in a dynamic object mapping that maps Names => Values. It stores metadata about
   /// a particular CoinType, or equivalently a CoinTypeWrapper.
   struct WrappedAssetInfo<phantom CoinType> has key, store {
      id: UID,
      token_chain: U16,
      token_address: ExternalAddress,
      // TODO: add the following when coin metadata is on 'devnet'
      // coin_meta: CoinMetadata<CoinType>,
   }

   struct NativeAssetInfo<phantom CoinType> has key, store {
      id: UID,
      // Even though we can look up token_chain at any time from wormhole state,
      // it can be more efficient to store it here locally so we don't have to do lookups.
      token_chain: U16,
      // We assign a unique identifier token_address to a Sui-native token
      // in the form of a 32-byte ExternalAddress
      token_address: ExternalAddress,
      symbol: String32,
      name: String32,
      decimals: u64,
   }

   /// OriginInfo is a non-Sui object that stores info about a tokens native token
   /// chain and address
   struct OriginInfo<phantom CoinType> has store, copy, drop {
      token_chain: U16,
      token_address: ExternalAddress,
   }

   public(friend) fun create_origin_info<CoinType>(token_chain: U16, token_address: ExternalAddress): OriginInfo<CoinType> {
      return OriginInfo {
         token_chain,
         token_address
      }
   }

   public fun get_token_chain_from_origin_info<CoinType>(origin_info: &OriginInfo<CoinType>): U16 {
      return origin_info.token_chain
   }

   public fun get_token_address_from_origin_info<CoinType>(origin_info: &OriginInfo<CoinType>): ExternalAddress {
      return origin_info.token_address
   }

   public fun get_origin_info_from_wrapped_asset_info<CoinType>(wrapped_asset_info: &WrappedAssetInfo<CoinType>): OriginInfo<CoinType> {
      create_origin_info(wrapped_asset_info.token_chain, wrapped_asset_info.token_address)
   }

   public fun get_origin_info_from_native_asset_info<CoinType>(native_asset_info: &NativeAssetInfo<CoinType>): OriginInfo<CoinType> {
      create_origin_info(native_asset_info.token_chain, native_asset_info.token_address)
   }

   public(friend) fun create_wrapped_asset_info<CoinType>(token_chain: U16, token_address: ExternalAddress, ctx: &mut TxContext): WrappedAssetInfo<CoinType> {
      return WrappedAssetInfo {
         id: object::new(ctx),
         token_chain: token_chain,
         token_address: token_address
      }
   }

   // Treasury caps, token stores, consumed VAAs, registered emitters, etc.
   // are stored as dynamic fields of bridge state.
   struct BridgeState has key, store {
      id: UID,

      /// Set of consumed VAA hashes
      consumed_vaas: Set<vector<u8>>,

      /// Token bridge owned emitter capability
      emitter_cap: option::Option<EmitterCapability>,

      // Mapping of bridge contracts on other chains
      // TODO - is it is OK to keep this?
      //        there will likely never be a few 100s of other bridge contracts
      registered_emitters: VecMap<U16, ExternalAddress>,
   }

   fun init(ctx: &mut TxContext) {
        transfer::transfer(DeployerCapability{id: object::new(ctx)}, tx_context::sender(ctx));
    }

   #[test_only]
   public fun test_init(ctx: &mut TxContext) {
      transfer::transfer(DeployerCapability{id: object::new(ctx)}, tx_context::sender(ctx));
   }

   // converts owned state object into a shared object, so that anyone can get a reference to &mut State
   // and pass it into various functions
   public entry fun init_and_share_state(
      deployer: DeployerCapability,
      emitter_cap: EmitterCapability,
      ctx: &mut TxContext
   ) {
      let DeployerCapability{id} = deployer;
      object::delete(id);
      let state = BridgeState {
         id: object::new(ctx),
         consumed_vaas: set::new(ctx),
         emitter_cap: option::some(emitter_cap),
         registered_emitters: vec_map::empty(),
      };

      // permanently shares state
      transfer::share_object(state);
   }

   public(friend) fun deposit<CoinType>(
      bridge_state: &mut BridgeState,
      coin: Coin<CoinType>,
      ctx: &mut TxContext
   ) {
      if (!dynamic_set::exists_<CoinStore<CoinType>>(&mut bridge_state.id)) {

         // If coin_store<CoinType> does not exist as a dynamic object field of bridge_state,
         // we create a new one and attach it to bridge_state as a dynamic field
         let coin_store = treasury::create_coin_store<CoinType>(ctx);
         store_coin_store<CoinType>(bridge_state, coin_store)

      };
      let coin_store = dynamic_set::borrow_mut<CoinStore<CoinType>>(&mut bridge_state.id);
      treasury::deposit<CoinType>(coin_store, coin);
   }

   public(friend) fun withdraw<CoinType>(
      bridge_state: &mut BridgeState,
      value: u64,
      ctx: &mut TxContext
   ): Coin<CoinType> {
      let coin_store = dynamic_set::borrow_mut<CoinStore<CoinType>>(&mut bridge_state.id);
      let coins = treasury::withdraw<CoinType>(coin_store, value, ctx);
      return coins
   }

   public(friend) fun mint<CoinType>(
      bridge_state: &mut BridgeState,
      value: u64,
      ctx: &mut TxContext,
   ): Coin<CoinType> {
      // TODO: what if the treasury cap store does not exist as a dynamic field of Bridge State ?
      let treasury_cap_store = dynamic_set::borrow_mut<TreasuryCapStore<CoinType>>(&mut bridge_state.id);
      let coins = treasury::mint<CoinType>(treasury_cap_store, value, ctx);
      return coins
   }

   public(friend) fun burn<CoinType>(
      bridge_state: &mut BridgeState,
      coin: Coin<CoinType>,
   ) {
      let treasury_cap_store = dynamic_set::borrow_mut<TreasuryCapStore<CoinType>>(&mut bridge_state.id);
      treasury::burn<CoinType>(treasury_cap_store, coin);
   }

   public(friend) fun publish_message(
      wormhole_state: &mut State,
      bridge_state: &mut BridgeState,
      nonce: u64,
      payload: vector<u8>,
      message_fee: Coin<SUI>,
   ): u64 {
      wormhole::publish_message(
         option::borrow_mut<EmitterCapability>(&mut bridge_state.emitter_cap),
         wormhole_state,
         nonce,
         payload,
         message_fee,
      )
   }

   /// getters

   public fun vaa_is_consumed(state: &BridgeState, hash: vector<u8>): bool {
      set::contains(&state.consumed_vaas, hash)
   }

   public fun get_registered_emitter(state: &BridgeState, chain_id: &U16): Option<ExternalAddress> {
      if (vec_map::contains(&state.registered_emitters, chain_id)) {
         option::some(*vec_map::get(&state.registered_emitters, chain_id))
      } else {
         option::none()
      }
   }

   public fun is_wrapped_asset<CoinType>(bridge_state: &BridgeState): bool {
      dynamic_set::exists_<WrappedAssetInfo<CoinType>>(&bridge_state.id)
   }

    public fun is_registered_native_asset<CoinType>(bridge_state: &BridgeState): bool {
      dynamic_set::exists_<NativeAssetInfo<CoinType>>(&bridge_state.id)
   }

   public fun get_wrapped_asset_origin_info<CoinType>(bridge_state: &BridgeState): OriginInfo<CoinType> {
      assert!(is_wrapped_asset<CoinType>(bridge_state), E_IS_NOT_WRAPPED_ASSET);
      let wrapped_asset_info = dynamic_set::borrow<WrappedAssetInfo<CoinType>>(&bridge_state.id);
      get_origin_info_from_wrapped_asset_info(wrapped_asset_info)
   }

   public fun get_registered_native_asset_origin_info<CoinType>(bridge_state: &BridgeState): OriginInfo<CoinType> {
      assert!(is_wrapped_asset<CoinType>(bridge_state), E_IS_NOT_REGISTERED_NATIVE_ASSET);
      let native_asset_info = dynamic_set::borrow<NativeAssetInfo<CoinType>>(&bridge_state.id);
      get_origin_info_from_native_asset_info(native_asset_info)
   }

   /// setters

   public(friend) fun set_registered_emitter(state: &mut BridgeState, chain_id: U16, emitter: ExternalAddress) {
      vec_map::insert<U16, ExternalAddress>(&mut state.registered_emitters, chain_id, emitter);
   }

   /// dynamic ops

   public(friend) fun store_treasury_cap<T>(state: &mut BridgeState, treasury_cap_store: treasury::TreasuryCapStore<T>) {
       // store the treasury_cap_store as a dynamic field of bridge state
      dynamic_set::add<treasury::TreasuryCapStore<T>>(&mut state.id, treasury_cap_store);
   }

   public(friend) fun store_coin_store<T>(state: &mut BridgeState, treasury_coin_store: treasury::CoinStore<T>) {
      // store the coin store as a dynamic field of bridge state
      dynamic_set::add<treasury::CoinStore<T>>(&mut state.id, treasury_coin_store);
   }

   public(friend) fun store_consumed_vaa(bridge_state: &mut BridgeState, vaa: vector<u8>) {
      set::add(&mut bridge_state.consumed_vaas, vaa);
   }

   public(friend) fun register_wrapped_asset<CoinType>(bridge_state: &mut BridgeState, wrapped_asset_info: WrappedAssetInfo<CoinType>) {
      dynamic_set::add<WrappedAssetInfo<CoinType>>(&mut bridge_state.id, wrapped_asset_info);
   }

    public(friend) fun register_native_asset<CoinType>(bridge_state: &mut BridgeState, native_asset_info: NativeAssetInfo<CoinType>) {
      dynamic_set::add<NativeAssetInfo<CoinType>>(&mut bridge_state.id, native_asset_info);
   }

}

#[test_only]
module token_bridge::test_bridge_state{
   use sui::test_scenario::{Self, Scenario, next_tx, ctx, take_from_address, take_shared, return_shared};

   use wormhole::state::{State};
   use wormhole::test_state::{init_wormhole_state};
   use wormhole::wormhole::{Self};

   use token_bridge::bridge_state::{Self, BridgeState, test_init};

   fun scenario(): Scenario { test_scenario::begin(@0x123233) }
   fun people(): (address, address, address) { (@0x124323, @0xE05, @0xFACE) }

   #[test]
   fun test_state_setters() {
      test_state_setters_(scenario())
   }

   public fun set_up_wormhole_core_and_token_bridges(admin: address, test: Scenario): Scenario {
      // init and share wormhole core bridge
      test =  init_wormhole_state(test, admin);

      // call init for token bridge to get deployer cap
      next_tx(&mut test, admin); {
         test_init(ctx(&mut test));
      };

      // register for emitter cap and init_and_share token bridge
      next_tx(&mut test, admin); {
         let wormhole_state = take_shared<State>(&test);
         let my_emitter = wormhole::register_emitter(&mut wormhole_state, ctx(&mut test));
         let deployer = take_from_address<bridge_state::DeployerCapability>(&test, admin);
         bridge_state::init_and_share_state(deployer, my_emitter, ctx(&mut test));
         return_shared<State>(wormhole_state);
      };

      next_tx(&mut test, admin); {
         let bridge_state = take_shared<BridgeState>(&test);
         return_shared<BridgeState>(bridge_state);
      };

      return test
   }

   fun test_state_setters_(test: Scenario) {
      let (admin, _, _) = people();

      test = set_up_wormhole_core_and_token_bridges(admin, test);

      //test BridgeState setter and getter functions
      next_tx(&mut test, admin); {
         let state = take_shared<BridgeState>(&test);

         // test store consumed vaa
         bridge_state::store_consumed_vaa(&mut state, x"1234");
         assert!(bridge_state::vaa_is_consumed(&state, x"1234"), 0);

         // TODO - test store coin store
         // TODO - test store treasury cap

         return_shared<BridgeState>(state);
      };
      test_scenario::end(test);
   }

   // TODO - Test deposit and withdraw from the token bridge off-chain

}
