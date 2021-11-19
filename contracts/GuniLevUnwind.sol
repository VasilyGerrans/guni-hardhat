// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "./GuniLev.sol";
import "./utils.sol";

contract GuniLevUnwind is Initializable, IERC3156FlashBorrower {
    uint256 constant RAY = 10 ** 27;

    VatLike public vat;
    DaiJoinLike public daiJoin;
    SpotLike public spotter;
    IERC20 public dai;
    IERC3156FlashLender public lender;
    GUNIRouterLike public router;
    GUNIResolverLike public resolver;

    address private parentAddress;

    function initialize(address _parent) external initializer() {
        parentAddress = _parent;
        GuniLev parent = GuniLev(parentAddress);
        vat = parent.vat();
        daiJoin = parent.daiJoin();
        spotter = parent.spotter();
        dai = parent.dai();
        lender = parent.lender();
        router = parent.router();
        resolver = parent.resolver();

        VatLike(vat).hope(address(daiJoin));
    }

    modifier onlyParent() {
        require(parentAddress == msg.sender);
        _;
    }

    function getUnwindEstimates(bytes32 ilk, uint256 ink, uint256 art) public view onlyParent returns (uint256 estimatedDaiRemaining) {
        (
            ,,
            CurveSwapLike curve,
            int128 curveIndexDai,
            int128 curveIndexOtherToken,
            ,
            GUNITokenLike guni
        ) = GuniLev(parentAddress).getPoolWinder(ilk);

        (,uint256 rate,,,) = vat.ilks(ilk);
        (uint256 bal0, uint256 bal1) = guni.getUnderlyingBalances();
        uint256 totalSupply = guni.totalSupply();
        bal0 = bal0 * ink / totalSupply;
        bal1 = bal1 * ink / totalSupply;
        uint256 dy = curve.get_dy(curveIndexOtherToken, curveIndexDai, guni.token0() == address(dai) ? bal1 : bal0);

        return (guni.token0() == address(dai) ? bal0 : bal1) + dy - art * rate / RAY;
    }

    function getUnwindEstimates(bytes32 ilk, address usr) external view onlyParent returns (uint256 estimatedDaiRemaining) {
        (uint256 ink, uint256 art) = vat.urns(ilk, usr);
        return getUnwindEstimates(ilk, ink, art);
    }

    function unwind(bytes32 ilk, address sender, uint256 minWalletDai) external onlyParent {
        bytes memory data = abi.encode(ilk, sender, minWalletDai);
        (,uint256 rate,,,) = vat.ilks(ilk);
        (, uint256 art) = vat.urns(ilk, msg.sender);
        initFlashLoan(data, art*rate/RAY);
    }

    function initFlashLoan(bytes memory data, uint256 amount) internal {
        uint256 _allowance = dai.allowance(address(this), address(lender));
        uint256 _fee = lender.flashFee(address(dai), amount);
        uint256 _repayment = amount + _fee;
        dai.approve(address(lender), _allowance + _repayment);
        lender.flashLoan(this, address(dai), amount, data);
    }

    function onFlashLoan(
        address initiator,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        require(
            msg.sender == address(lender),
            "FlashBorrower: Untrusted lender"
        );
        require(
            initiator == address(this),
            "FlashBorrower: Untrusted loan initiator"
        );
        (bytes32 ilk, address usr, uint256 minWalletDai) = abi.decode(data, (bytes32, address, uint256));
        _unwind(ilk, usr, amount, fee, minWalletDai);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function _unwind(bytes32 ilk, address usr, uint256 amount, uint256 fee, uint256 minWalletDai) internal {
        (   
            ,
            IERC20 otherToken,
            CurveSwapLike curve, 
            int128 curveIndexDai, 
            int128 curveIndexOtherToken,
            ,
        )
        = GuniLev(parentAddress).getPoolWinder(ilk);
        
        // Pay back all CDP debt and exit g-uni
        _payBackDebtAndExitGuni(ilk, usr, amount);

        // Trade all otherToken for dai
        uint256 swapAmount = otherToken.balanceOf(address(this));
        otherToken.approve(address(curve), swapAmount);
        curve.exchange(curveIndexOtherToken, curveIndexDai, swapAmount, 0);

        uint256 daiBalance = dai.balanceOf(address(this));
        uint256 totalOwed = amount + fee;
        if (daiBalance > totalOwed) {
            // Send extra dai to user
            dai.transfer(usr, daiBalance - totalOwed);
        } else if (daiBalance < totalOwed) {
            // Pull remaining dai needed from usr
            dai.transferFrom(usr, address(this), totalOwed - daiBalance);
        }

        // Send any remaining dust from other token to user as well
        otherToken.transfer(usr, otherToken.balanceOf(address(this)));

        require(dai.balanceOf(address(usr)) + otherToken.balanceOf(address(this)) >= minWalletDai, "slippage");
    }

    /// @dev Separated to escape the 'stack too deep' error
    function _payBackDebtAndExitGuni(bytes32 ilk, address usr, uint256 amount) internal {
        (
            GemJoinLike join,
            ,,,,,
            GUNITokenLike guni
        ) = GuniLev(parentAddress).getPoolWinder(ilk);

        (uint256 ink, uint256 art) = vat.urns(ilk, usr);
        dai.approve(address(daiJoin), amount);
        daiJoin.join(address(this), amount);
        vat.frob(ilk, address(usr), address(this), address(this), -int256(ink), -int256(art));
        join.exit(address(this), ink);

        // Burn G-UNI
        guni.approve(address(router), ink);
        router.removeLiquidity(address(guni), ink, 0, 0, address(this));
    }
}