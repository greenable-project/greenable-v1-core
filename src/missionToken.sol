// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MissionToken is ERC20 {
  address public controller; // @note : 이 토큰을 제어하는 MissionProtocol 컨트랙트
  IERC20 public immutable underlyingToken; // @note : 이 토큰이 래핑하는 기본 토큰
  bool public immutable transferable; // @note : 일반 사용자에게 토큰 전송이 허용되는지 여부
  
  // @note : 토큰 결제를 받을 수 있는 승인된 가맹점들을 추적하는 매핑
  mapping(address => bool) public authorizedMerchants;

  modifier onlyAuthorizedMerchant() {
    require(authorizedMerchants[msg.sender], "not authorized merchant");
    _;
  }

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
    
    // @note : 배포 시 승인된 가맹점들 초기화
    for (uint256 i = 0; i < _authorizedMerchants.length; i++) {
      authorizedMerchants[_authorizedMerchants[i]] = true;
    }
  }

  function setController(address c) external { 
    require(msg.sender == controller, "not controller");
    controller = c; 
  }

  function addMerchant(address merchant) external {
    require(msg.sender == controller, "not controller");
    authorizedMerchants[merchant] = true;
  }

  function removeMerchant(address merchant) external {
    require(msg.sender == controller, "not controller");
    authorizedMerchants[merchant] = false;
  }

  function mint(uint256 amount) external {
    require(msg.sender == controller, "not controller");
    
    // @note : 기본 토큰을 이 컨트랙트로 전송받음
    require(underlyingToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
    
    // @note : controller에게 동일한 양의 래핑된 토큰을 mint
    _mint(msg.sender, amount);
  }

  function burnFrom(address from, uint256 amount) external {
    require(msg.sender == controller, "not controller");
    _burn(from, amount);
  }

  // @note : 가맹점에서 토큰 사용 (소각 후 기본 토큰 지급)
  function payToMerchant(address user, uint256 amount) external onlyAuthorizedMerchant {
    _burn(user, amount);
    // @note : 기본 토큰을 가맹점에게 전송
    require(underlyingToken.transfer(msg.sender, amount), "transfer failed");
  }

  // @note : 전송 관련 기능 - controller는 항상 가능, 일반 사용자는 transferable 설정에 따라
  function transfer(address to, uint256 amount) public override returns (bool) {
    if (!transferable && msg.sender != controller) {
      revert("non-transferable");
    }
    return super.transfer(to, amount);
  }

  function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    if (!transferable && msg.sender != controller) {
      revert("non-transferable");
    }
    return super.transferFrom(from, to, amount);
  }

  function approve(address spender, uint256 amount) public override returns (bool) {
    if (!transferable && msg.sender != controller && spender != controller) {
      revert("non-transferable");
    }
    return super.approve(spender, amount);
  }
}
