// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "./GuniLevWind.sol";
import "./GuniLevUnwind.sol";
import "./utils.sol";

contract GuniLev is Initializable, OwnableUpgradeable {
    uint256 constant RAY = 10 ** 27;

    bytes32 public ilk;

    VatLike public vat;
    DaiJoinLike public daiJoin;
    SpotLike public spotter;
    IERC20 public dai;
    IERC3156FlashLender public lender;
    GUNIRouterLike public router;
    GUNIResolverLike public resolver;

    GuniLevWind private winder;
    GuniLevUnwind private unwinder;

    function setWinders(address _winder, address _unwinder) external onlyOwner {
        require(address(winder) == address(0) || address(unwinder) == address(0));
        winder = GuniLevWind(_winder);
        unwinder = GuniLevUnwind(_unwinder);
    }

    struct PoolWinder { 
        GemJoinLike join;
        IERC20 otherToken;
        CurveSwapLike curve;
        int128 curveIndexDai;
        int128 curveIndexOtherToken;
        uint256 otherTokenTo18Conversion;
        GUNITokenLike guni;
    }

    mapping(bytes32 => bool) private poolWinderExists;
    mapping(bytes32 => PoolWinder) private poolWinders;

    function getPoolWinder(bytes32 _ilk) external view returns (
        GemJoinLike join,
        IERC20 otherToken,
        CurveSwapLike curve,
        int128 curveIndexDai,
        int128 curveIndexOtherToken,
        uint256 otherTokenTo18Conversion,
        GUNITokenLike guni
    ) {
        return (
            poolWinders[_ilk].join,
            poolWinders[_ilk].otherToken,
            poolWinders[_ilk].curve,
            poolWinders[_ilk].curveIndexDai,
            poolWinders[_ilk].curveIndexOtherToken,
            poolWinders[_ilk].otherTokenTo18Conversion,
            poolWinders[_ilk].guni
        );
    }

    function initialize(
        address _joinAddress,
        address _daiJoinAddress,
        address _spotterAddress,
        address _lenderAddress,
        address _routerAddress,
        address _resolverAddress,
        address _curveAddress,
        int128 _curveIndexDai,
        int128 _curveIndexOtherToken
    ) external initializer() {
        GemJoinLike join = GemJoinLike(_joinAddress);
        vat = VatLike(join.vat());
        daiJoin = DaiJoinLike(_daiJoinAddress);
        spotter = SpotLike(_spotterAddress);
        dai = IERC20(daiJoin.dai());
        lender = IERC3156FlashLender(_lenderAddress);
        router = GUNIRouterLike(_routerAddress);
        resolver = GUNIResolverLike(_resolverAddress);
        CurveSwapLike curve = CurveSwapLike(_curveAddress);

        __Ownable_init();

        require(setPool(join, curve, _curveIndexDai, _curveIndexOtherToken) == true);

        ilk = join.ilk();
    }   

    function setIlk(bytes32 newIlk) external onlyOwner {
        ilk = newIlk;
    } 

    /// @notice Creates new or overwrites existing PoolWinder.
    function setPool(GemJoinLike join, CurveSwapLike curve, int128 curveIndexDai, int128 curveIndexOtherToken) 
    public onlyOwner returns (bool success) {
        require(curve.coins(smallIntToUint(curveIndexDai)) == address(dai));
        
        GUNITokenLike guni = GUNITokenLike(join.gem());
        IERC20 otherToken = guni.token0() != address(dai) ? IERC20(guni.token0()) : IERC20(guni.token1());
        require(curve.coins(smallIntToUint(curveIndexOtherToken)) == address(otherToken));
        
        bytes32 newIlk = join.ilk();
        poolWinderExists[newIlk] = true;
        poolWinders[newIlk] = PoolWinder(
            join, 
            otherToken, 
            curve, 
            curveIndexDai, 
            curveIndexOtherToken, 
            10 ** (18 - otherToken.decimals()),
            guni
        );

        return true;
    }    

    /// @notice Makes existing pool inaccessible.
    function deletePool(bytes32 _ilk) external onlyOwner returns(bool success) {
        require(poolWinderExists[_ilk] == true, "GuniLevProxy/deletePool/pool-does-not-exist");
        poolWinderExists[_ilk] = false;
        return true;
    }

    /// @notice A hack workaround for converting int128 to uint256. This issue is introduced
    /// by curve.exchange and curve.coins functions that accept int128 and uint256 respectively.
    /// This shouldn't introduce major gas costs so long as the Curve pool has few coins
    /// in the pool (which it typically does). It should also never throw an error, as curve
    /// coin indexes are always positive.
    function smallIntToUint(int128 valInitial) internal pure returns (uint256) {
        require(valInitial >= 0);
        uint256 valFinal;
        for (int128 index = 0; index < valInitial; index++) {
            valFinal++;
        }
        return valFinal;
    }

    function getLeverageBPS(bytes32 _ilk) external view returns (uint256) {
        (,uint256 mat) = spotter.ilks(_ilk);
        return 10000 * RAY/(mat - RAY);
    }

    function getEstimatedCostToWindUnwind(address usr, uint256 principal) external view returns (uint256) {
        (, uint256 estimatedGuniAmount, uint256 estimatedDebt) = winder.getWindEstimates(ilk, usr, principal);
        (,uint256 rate,,,) = vat.ilks(ilk);
        return dai.balanceOf(usr) - unwinder.getUnwindEstimates(ilk, estimatedGuniAmount, estimatedDebt * RAY / rate);
    }

    function getWindEstimates(address usr, uint256 principal) external view returns (uint256 estimatedDaiRemaining, uint256 estimatedGuniAmount, uint256 estimatedDebt) {
        return winder.getWindEstimates(ilk, usr, principal);
    }

    function wind(uint256 principal, uint256 minWalletDai) external {
        winder.wind(ilk, msg.sender, principal, minWalletDai);
    }

    function getUnwindEstimates(address usr) external view returns (uint256 estimatedDaiRemaining) {
        return unwinder.getUnwindEstimates(ilk, usr);
    }

    function unwind(uint256 minWalletDai) external {
        unwinder.unwind(ilk, msg.sender, minWalletDai);
    }
}
