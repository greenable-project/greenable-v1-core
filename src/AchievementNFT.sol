// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AchievementNFT
 * @dev 업적 NFT(ERC721), owner만 mint 가능, missionId는 optional
 */
contract AchievementNFT is ERC721, Ownable {

    /// @dev tuple 접근 불가하므로 별도 getter 제공
    function getAchievementInfo(uint256 tokenId) external view returns (uint256 missionId, string memory metadataURI) {
        AchievementInfo memory info = achievementInfos[tokenId];
        missionId = info.missionId;
        metadataURI = info.metadataURI;
    }
    uint256 public nextTokenId = 1;

    struct AchievementInfo {
        uint256 missionId; // 0이면 미션과 무관
        string metadataURI;
    }

    mapping(uint256 => AchievementInfo) public achievementInfos;

    event AchievementMinted(address indexed to, uint256 indexed tokenId, uint256 missionId, string metadataURI);

    constructor(string memory name_, string memory symbol_) Ownable(msg.sender) ERC721(name_, symbol_) {}

    /**
     * @dev owner만 업적 NFT 발행. missionId=0이면 미션 무관 업적
     * @param to 수령자
     * @param missionId 연결할 미션 번호(없으면 0)
     * @param metadataURI 업적 메타데이터(이미지/설명 등)
     */
    function mint(address to, uint256 missionId, string memory metadataURI) external onlyOwner returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _mint(to, tokenId);
        achievementInfos[tokenId] = AchievementInfo({missionId: missionId, metadataURI: metadataURI});
        emit AchievementMinted(to, tokenId, missionId, metadataURI);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Nonexistent token");
        return achievementInfos[tokenId].metadataURI;
    }
}
