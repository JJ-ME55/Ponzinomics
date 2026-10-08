# Hot spots — static pre-scan, local HEAD e9d2da4

Scope: 1,188 lines. src/pimd/{PimdToken,PimdHook,PimdEngine}.sol, src/libraries/L2Block.sol, script/DeployPimd.s.sol

## assembly
  src/pimd/PimdEngine.sol:517:        assembly ("memory-safe") {
  src/pimd/PimdHook.sol:511:        assembly {
  src/pimd/PimdHook.sol:517:        assembly {

## \.call{
  src/pimd/PimdEngine.sol:488:            address(imd).call{gas: SEND_GAS}(abi.encodeCall(IERC20Min.transfer, (to, amount)));

## staticcall
  src/libraries/L2Block.sol:17:        (bool ok, bytes memory ret) = ARBSYS.staticcall{gas: ARBSYS_GAS}(abi.encodeWithSignature("arbBlockNumber()"));
  src/pimd/PimdEngine.sol:509:    /// probe is a gas-capped staticcall that reads at most one word of return data.
  src/pimd/PimdEngine.sol:520:            let ok := staticcall(PROBE_GAS, a, ptr, 4, ptr, 32)

## _tstore\|_tload
  src/pimd/PimdHook.sol:285:            _tstore(_SPEC_SLOT, amt);
  src/pimd/PimdHook.sol:287:        _tstore(_FEE_SLOT, fee);
  src/pimd/PimdHook.sol:296:        uint256 fee = _tload(_FEE_SLOT);
  src/pimd/PimdHook.sol:297:        uint256 specified = _tload(_SPEC_SLOT);
  src/pimd/PimdHook.sol:298:        _tstore(_FEE_SLOT, 0);
  src/pimd/PimdHook.sol:299:        _tstore(_SPEC_SLOT, 0);
  src/pimd/PimdHook.sol:413:        _tstore(_UNLOCK_SLOT, 1);
  src/pimd/PimdHook.sol:415:        _tstore(_UNLOCK_SLOT, 0);
  src/pimd/PimdHook.sol:437:        _tstore(_UNLOCK_SLOT, 1);
  src/pimd/PimdHook.sol:439:        _tstore(_UNLOCK_SLOT, 0);
  src/pimd/PimdHook.sol:447:        if (_tload(_UNLOCK_SLOT) != 1) revert NotUnlocking();
  src/pimd/PimdHook.sol:510:    function _tstore(uint256 slot, uint256 value) private {
  src/pimd/PimdHook.sol:516:    function _tload(uint256 slot) private view returns (uint256 value) {

## tx\.origin
  src/pimd/PimdHook.sol:104:    uint128 public constant launchBuyCap = 25e18; // IMD one tx.origin may spend in the launch window
  src/pimd/PimdHook.sol:325:        // first seconds. The cap is per tx.origin, applies for a short window, and is bounded by both blocks
  src/pimd/PimdHook.sol:334:                uint256 total = launchBuys[tx.origin] + spent;
  src/pimd/PimdHook.sol:336:                launchBuys[tx.origin] = total;

## unchecked

## try \|catch
  src/pimd/PimdEngine.sol:274:            try hook.flush() {} catch {}
  src/pimd/PimdToken.sol:14:/// `balanceOf` by the engine, so this needs no hooks, no registry and no per-transfer bookkeeping: a

## delegatecall

## selfdestruct

## narrowing casts
  src/pimd/PimdEngine.sol:234:            h.index1 = uint64(holders.length);
  src/pimd/PimdEngine.sol:235:            h.lastBal = uint128(bal);
  src/pimd/PimdEngine.sol:236:            h.streakStart = uint64(block.timestamp); // the clock starts at registration, never earlier
  src/pimd/PimdEngine.sol:256:            _holder[last].index1 = uint64(idx1);
  src/pimd/PimdEngine.sol:321:                h.streakStart = uint64(nowTs); // sold or sent out: the clock restarts
  src/pimd/PimdEngine.sol:324:                h.streakStart = uint64((last * h.streakStart + (bal - last) * nowTs) / bal);
  src/pimd/PimdEngine.sol:326:            h.lastBal = uint128(bal);
  src/pimd/PimdEngine.sol:329:            h.weight = uint128(w);
  src/pimd/PimdEngine.sol:370:                h.received += uint128(amt);
  src/pimd/PimdHook.sol:257:        initBlock = uint64(L2Block.number());
  src/pimd/PimdHook.sol:258:        launchStart = uint64(block.timestamp);
  src/pimd/PimdHook.sol:288:        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
  src/pimd/PimdHook.sol:309:            uint256 movedQuote = a0q < 0 ? uint256(uint128(-a0q)) : uint256(uint128(a0q));
  src/pimd/PimdHook.sol:317:            uint256 quoteAmt = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
  src/pimd/PimdHook.sol:321:            hookDeltaUnspecified = int128(uint128(fee));
  src/pimd/PimdHook.sol:333:                uint256 spent = uint256(uint128(-delta.amount0())) + fee;
