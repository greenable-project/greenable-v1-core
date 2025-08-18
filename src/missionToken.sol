// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MissionToken
 * @dev 미션 보상 토큰 - 기본 토큰(원화 스테이블코인)을 래핑하여 가맹점 제한 기능을 제공
 */
contract MissionToken is ERC20 {
    // 상태 변수
    address public controller; // 이 토큰을 제어하는 MissionProtocol 컨트랙트
    IERC20 public immutable underlyingToken; // 이 토큰이 래핑하는 기본 토큰
    bool public immutable transferable; // 일반 사용자에게 토큰 전송이 허용되는지 여부

    // 토큰 결제를 받을 수 있는 승인된 가맹점들을 추적하는 매핑
    mapping(address => bool) public authorizedMerchants;

    // 이벤트
    event MerchantAdded(address indexed merchant);
    event MerchantRemoved(address indexed merchant);
    event PaymentProcessed(address indexed user, address indexed merchant, uint256 amount);
    event ControllerChanged(address indexed oldController, address indexed newController);

    // 에러
    error NotController();
    error NotAuthorizedMerchant();
    error TransferNotAllowed();

    // 수정자
    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    modifier onlyAuthorizedMerchant() {
        if (!authorizedMerchants[msg.sender]) revert NotAuthorizedMerchant();
        _;
    }

    /**
     * @dev 컨트랙트 생성자
     * @param name 토큰 이름
     * @param symbol 토큰 심볼
     * @param _underlyingToken 기본 토큰 주소
     * @param _transferable 전송 가능 여부
     * @param _authorizedMerchants 초기 승인된 가맹점 배열
     */
    constructor(
        string memory name,
        string memory symbol,
        address _underlyingToken,
        bool _transferable,
        address[] memory _authorizedMerchants
    ) ERC20(name, symbol) {
        controller = msg.sender;
        underlyingToken = IERC20(_underlyingToken);
        transferable = _transferable;

        // 배포 시 승인된 가맹점들 초기화
        for (uint256 i = 0; i < _authorizedMerchants.length; i++) {
            authorizedMerchants[_authorizedMerchants[i]] = true;
            emit MerchantAdded(_authorizedMerchants[i]);
        }
    }

    /**
     * @dev 컨트롤러 주소 변경 (현재 컨트롤러만 가능)
     * @param newController 새로운 컨트롤러 주소
     */
    function setController(address newController) external onlyController {
        address oldController = controller;
        controller = newController;
        emit ControllerChanged(oldController, newController);
    }

    /**
     * @dev 승인된 가맹점 추가
     * @param merchant 추가할 가맹점 주소
     */
    function addMerchant(address merchant) external onlyController {
        authorizedMerchants[merchant] = true;
        emit MerchantAdded(merchant);
    }

    /**
     * @dev 승인된 가맹점 제거
     * @param merchant 제거할 가맹점 주소
     */
    function removeMerchant(address merchant) external onlyController {
        authorizedMerchants[merchant] = false;
        emit MerchantRemoved(merchant);
    }

    /**
     * @dev 기본 토큰을 예치하고 MissionToken을 발행
     * @param amount 발행할 토큰 양
     */
    function mint(uint256 amount) external onlyController {
        // 기본 토큰을 이 컨트랙트로 전송받음
        require(underlyingToken.transferFrom(msg.sender, address(this), amount), "transfer failed");

        // controller에게 동일한 양의 래핑된 토큰을 mint
        _mint(msg.sender, amount);
    }

    /**
     * @dev 지정된 주소에서 토큰을 소각
     * @param from 토큰을 소각할 주소
     * @param amount 소각할 토큰 양
     */
    function burnFrom(address from, uint256 amount) external onlyController {
        _burn(from, amount);
    }

    /**
     * @dev 사용자가 인증된 가맹점에게 토큰 결제 (소각 후 기본 토큰 지급)
     * @param merchant 결제할 가맹점 주소
     * @param amount 결제할 토큰 양
     */
    function payToMerchant(address merchant, uint256 amount) external {
        if (!authorizedMerchants[merchant]) revert NotAuthorizedMerchant();

        _burn(msg.sender, amount);
        // 기본 토큰을 가맹점에게 전송
        require(underlyingToken.transfer(merchant, amount), "transfer failed");

        emit PaymentProcessed(msg.sender, merchant, amount);
    }

    /**
     * @dev 토큰 전송 (controller는 항상 가능, 일반 사용자는 transferable 설정에 따라)
     * @param to 받는 주소
     * @param amount 전송할 토큰 양
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!transferable && msg.sender != controller) {
            revert TransferNotAllowed();
        }
        return super.transfer(to, amount);
    }

    /**
     * @dev 승인된 토큰 전송 (controller는 항상 가능, 일반 사용자는 transferable 설정에 따라)
     * @param from 보내는 주소
     * @param to 받는 주소
     * @param amount 전송할 토큰 양
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!transferable && msg.sender != controller) {
            revert TransferNotAllowed();
        }
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev 토큰 사용 승인 (controller는 항상 가능, 일반 사용자는 transferable 설정에 따라)
     * @param spender 승인할 주소
     * @param amount 승인할 토큰 양
     */
    function approve(address spender, uint256 amount) public override returns (bool) {
        if (!transferable && msg.sender != controller && spender != controller) {
            revert TransferNotAllowed();
        }
        return super.approve(spender, amount);
    }

    /**
     * @dev 가맹점 승인 상태 확인
     * @param merchant 확인할 가맹점 주소
     * @return 승인 상태
     */
    function isMerchantAuthorized(address merchant) external view returns (bool) {
        return authorizedMerchants[merchant];
    }

    /**
     * @dev 컨트랙트에 보유된 기본 토큰 잔액 조회
     * @return 기본 토큰 잔액
     */
    function getUnderlyingBalance() external view returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }
}
