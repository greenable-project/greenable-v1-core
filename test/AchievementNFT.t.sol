// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MissionProtocol} from "../src/MissionProtocol.sol";
import {AchievementNFT} from "../src/AchievementNFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AchievementNFTTest is Test {
    MissionProtocol public protocol;
    AchievementNFT public nft;
    address public owner;
    address public user1 = address(0x123);
    address public user2 = address(0x456);

    function setUp() public {
        owner = address(this);
        protocol = new MissionProtocol(address(0x999));
        nft = AchievementNFT(protocol.achievementNFT());
    }

    function testMintAchievementNFTWithMissionId() public {
        string memory uri = "ipfs://test1";
        uint256 missionId = 42;
        uint256 tokenId = protocol.mintAchievementNFT(user1, missionId, uri);
    assertEq(nft.ownerOf(tokenId), user1);
    (uint256 gotMissionId, string memory gotUri) = nft.getAchievementInfo(tokenId);
    assertEq(gotMissionId, missionId);
    assertEq(gotUri, uri);
    assertEq(nft.tokenURI(tokenId), uri);
    }

    function testMintAchievementNFTWithoutMissionId() public {
        string memory uri = "ipfs://test2";
        uint256 tokenId = protocol.mintAchievementNFT(user2, 0, uri);
    assertEq(nft.ownerOf(tokenId), user2);
    (uint256 gotMissionId, string memory gotUri) = nft.getAchievementInfo(tokenId);
    assertEq(gotMissionId, 0);
    assertEq(gotUri, uri);
    assertEq(nft.tokenURI(tokenId), uri);
    }

    function testOnlyOwnerCanMint() public {
    vm.prank(user1);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
    protocol.mintAchievementNFT(user1, 1, "ipfs://fail");
    }
}
