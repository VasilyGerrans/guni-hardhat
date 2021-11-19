// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "./GuniLev.sol";
import "./utils.sol";

contract GuniLevWind is Initializable, IERC3156FlashBorrower {
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

    function getWindEstimates(
        bytes32 ilk,
        address usr, 
        uint256 principal
    ) public view onlyParent returns (uint256 estimatedDaiRemaining, uint256 estimatedGuniAmount, uint256 estimatedDebt) {
        uint256 leveragedAmount;
        {
            (,uint256 mat) = spotter.ilks(ilk);
            leveragedAmount = principal*RAY/(mat - RAY);
        }

        uint256 swapAmount;
        {
            (,,,,,
            uint256 otherTokenTo18Conversion,
            GUNITokenLike guni
            )
            = GuniLev(parentAddress).getPoolWinder(ilk);
            (uint256 sqrtPriceX96,,,,,,) = UniPoolLike(guni.pool()).slot0();
            (, swapAmount) = resolver.getRebalanceParams(
                address(guni),
                guni.token0() == address(dai) ? leveragedAmount : 0,
                guni.token1() == address(dai) ? leveragedAmount : 0,
                ((((sqrtPriceX96*sqrtPriceX96) >> 96) * 1e18) >> 96) * otherTokenTo18Conversion
            );
        }

        (estimatedGuniAmount, estimatedDebt) = _getGuniAmountAndDebt(ilk, usr, leveragedAmount, swapAmount);

        uint256 daiBalance = dai.balanceOf(usr);
       
        require(leveragedAmount <= estimatedDebt + daiBalance);

        estimatedDaiRemaining = estimatedDebt + daiBalance - leveragedAmount;
    }

    function _getGuniAmountAndDebt(bytes32 ilk, address usr, uint256 leveragedAmount, uint256 swapAmount) internal view returns (uint256 estimatedGuniAmount, uint256 estimatedDebt) {
        (,,
            CurveSwapLike curve, 
            int128 curveIndexDai, 
            int128 curveIndexOtherToken,
            ,
            GUNITokenLike guni
        )
        = GuniLev(parentAddress).getPoolWinder(ilk);
        (,, estimatedGuniAmount) = guni.getMintAmounts(
            guni.token0() == address(dai) ? leveragedAmount - swapAmount : curve.get_dy(curveIndexDai, curveIndexOtherToken, swapAmount), 
            guni.token1() == address(dai) ? leveragedAmount - swapAmount : curve.get_dy(curveIndexDai, curveIndexOtherToken, swapAmount));
        (,uint256 rate, uint256 spot,,) = vat.ilks(ilk);
        (uint256 ink, uint256 art) = vat.urns(ilk, usr);
        estimatedDebt = ((estimatedGuniAmount + ink) * spot / rate - art) * rate / RAY;
    }

    function wind(
        bytes32 ilk,
        address sender,
        uint256 principal,
        uint256 minWalletDai
    ) external onlyParent {
        bytes memory data = abi.encode(ilk, sender, minWalletDai);
        (,uint256 mat) = spotter.ilks(ilk);
        initFlashLoan(data, principal*RAY/(mat - RAY));
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
        _wind(ilk, usr, amount + fee, minWalletDai);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function _wind(bytes32 ilk, address usr, uint256 totalOwed, uint256 minWalletDai) internal {
        GuniLev parent = GuniLev(parentAddress); // make sure there's a test before doing this

        (,
        IERC20 otherToken,
        CurveSwapLike curve, 
        int128 curveIndexDai, 
        int128 curveIndexOtherToken,
        ,)
        = parent.getPoolWinder(ilk);

        // Calculate how much DAI we should be swapping for otherToken
        uint256 swapAmount;
        {
            (,,,,,uint256 otherTokenTo18Conversion,GUNITokenLike guni) = parent.getPoolWinder(ilk);
            (uint256 sqrtPriceX96,,,,,,) = UniPoolLike(guni.pool()).slot0();
            (, swapAmount) = resolver.getRebalanceParams(
                address(guni),
                IERC20(guni.token0()).balanceOf(address(this)),
                IERC20(guni.token1()).balanceOf(address(this)),
                ((((sqrtPriceX96*sqrtPriceX96) >> 96) * 1e18) >> 96) * otherTokenTo18Conversion
            );
        }

        // Swap DAI for otherToken on Curve
        dai.approve(address(curve), swapAmount);
        curve.exchange(curveIndexDai, curveIndexOtherToken, swapAmount, 0);

        _guniAndVaultLogic(ilk, parent, usr);

        uint256 daiBalance = dai.balanceOf(address(this));
        if (daiBalance > totalOwed) {
            // Send extra dai to user
            dai.transfer(usr, daiBalance - totalOwed);
        } else if (daiBalance < totalOwed) {
            // Pull remaining dai needed from usr
            dai.transferFrom(usr, address(this), totalOwed - daiBalance);
        }

        // Send any remaining dust from other token to user as well
        otherToken.transfer(usr, otherToken.balanceOf(address(this)));

        require(dai.balanceOf(address(usr)) + otherToken.balanceOf(address(usr)) >= minWalletDai, "slippage");
    }

    /// @dev Separated to escape the 'stack too deep' error
    function _guniAndVaultLogic(bytes32 ilk, GuniLev parent, address usr) internal {
        (
            GemJoinLike join,
            IERC20 otherToken,
            ,,,,
            GUNITokenLike guni
        ) = parent.getPoolWinder(ilk);

        // Mint G-UNI
        uint256 guniBalance;
        {
            uint256 bal0 = IERC20(guni.token0()).balanceOf(address(this));
            uint256 bal1 = IERC20(guni.token1()).balanceOf(address(this));
            dai.approve(address(router), bal0);
            otherToken.approve(address(router), bal1);
            (,, guniBalance) = router.addLiquidity(address(guni), bal0, bal1, 0, 0, address(this));
            dai.approve(address(router), 0);
            otherToken.approve(address(router), 0);
        }

        // Open / Re-enforce vault
        {
            guni.approve(address(join), guniBalance);
            join.join(address(usr), guniBalance); 
            (,uint256 rate, uint256 spot,,) = vat.ilks(ilk);
            (uint256 ink, uint256 art) = vat.urns(ilk, usr);
            uint256 dart = (guniBalance + ink) * spot / rate - art;
            vat.frob(ilk, address(usr), address(usr), address(this), int256(guniBalance), int256(dart)); 
            daiJoin.exit(address(this), vat.dai(address(this)) / RAY);
        }
    }
}