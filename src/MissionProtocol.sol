// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MissionToken} from "./missionToken.sol";
import {AchievementNFT} from "./AchievementNFT.sol";

/**
 * @title MissionProtocol
 * @dev 미션 등록, 검증서 제출, 보상 지급을 관리하는 핵심 프로토콜 컨트랙트
 */
contract MissionProtocol is ReentrancyGuard, Ownable {
    // (user, missionId)별 미션 수행 횟수 기록
    mapping(uint256 => mapping(address => uint256)) private _userMissionCompletions;

    function userMissionCompletions(uint256 missionId, address user) external view returns (uint256) {
        return _userMissionCompletions[missionId][user];
    }

    // 미션 수행 기록 이벤트
    event MissionCompleted(address indexed user, uint256 indexed missionId, uint256 newCount, uint256 date);

    // 업적 NFT 주소 (생성자에서 배포)
    address public achievementNFT;
    // 미션 제안 구조체

    struct MissionProposal {
        string name;
        string description;
        address creator;
        address underlyingToken;
        uint256 totalBudget;
        uint256 startDate;
        uint256 endDate;
        address[] authorizedVerifiers;
        address[] authorizedMerchants;
        bool transferable;
        bool approved;
    }

    // 미션 상태
    enum MissionStatus {
        Active, // 활성 상태
        Paused, // 일시 정지
        Ended // 종료됨

    }

    // 미션 구조체
    struct Mission {
        string name; // 미션 이름
        string description; // 미션 설명
        address creator; // 미션 생성자 (국가/지자체)
        address rewardToken; // 보상 토큰 (MissionToken 주소)
        uint256 totalBudget; // 총 예산
        uint256 spentBudget; // 사용된 예산
        uint256 startDate; // 시작일
        uint256 endDate; // 종료일
        MissionStatus status; // 미션 상태
        address[] authorizedVerifiers; // 승인된 검증기관들
    }

    // 사용자 참여 정보
    struct UserParticipation {
        uint256 totalRewardsEarned; // 총 받은 보상
    }

    // 검증서 구조체
    struct Attestation {
        address user; // 사용자 주소
        uint256 missionId; // 미션 ID
        uint256 date; // 활동 날짜 (YYYYMMDD)
        bytes32 dataHash; // 활동 데이터 해시
        bool processed; // 처리 완료 여부
    }

    // 배치 검증서 구조체
    struct BatchAttestation {
        address[] users; // 사용자 주소 배열
        uint256 missionId; // 미션 ID
        uint256 date; // 활동 날짜 (YYYYMMDD)
        bytes32[] dataHashes; // 활동 데이터 해시 배열
        uint256[] rewards; // 각 사용자별 보상 금액 배열
        address verifier; // 검증기관 주소
        bytes signature; // 검증기관 서명
    }

    // 상태 변수
    uint256 public nextMissionId = 1;
    mapping(uint256 => Mission) public missions;
    uint256 public nextProposalId = 1;
    mapping(uint256 => MissionProposal) public proposedMissions;
    mapping(uint256 => mapping(address => UserParticipation)) public userParticipations;
    mapping(bytes32 => bool) public processedAttestations; // 중복 처리 방지

    // 전역 설정
    uint256 public maxAttestationAge = 7; // 검증서 유효 기간 (일)
    address public defaultVerifier; // 기본 검증자 주소

    // 이벤트
    event AchievementNFTSet(address indexed nft);
    event AchievementNFTMinted(address indexed to, uint256 indexed tokenId, uint256 missionId, string metadataURI);
    /**
     * @dev 업적 NFT 컨트랙트 주소 설정 (owner only)
     */

    function setAchievementNFT(address _nft) external onlyOwner {
        achievementNFT = _nft;
        emit AchievementNFTSet(_nft);
    }

    /**
     * @dev owner가 유저에게 업적 NFT 발행 (missionId는 0 가능)
     */
    function mintAchievementNFT(address to, uint256 missionId, string memory metadataURI)
        external
        onlyOwner
        returns (uint256 tokenId)
    {
        require(achievementNFT != address(0), "NFT not set");
        // call AchievementNFT.mint
        (bool success, bytes memory data) =
            achievementNFT.call(abi.encodeWithSignature("mint(address,uint256,string)", to, missionId, metadataURI));
        require(success, "NFT mint failed");
        tokenId = abi.decode(data, (uint256));
        emit AchievementNFTMinted(to, tokenId, missionId, metadataURI);
    }

    event MissionProposed(
        uint256 indexed proposalId,
        string name,
        address indexed creator,
        address indexed underlyingToken,
        uint256 totalBudget
    );

    event MissionCreated(
        uint256 indexed missionId,
        string name,
        address indexed creator,
        address indexed rewardToken,
        uint256 totalBudget
    );

    event AttestationSubmitted(
        bytes32 indexed attestationHash, address indexed user, uint256 indexed missionId, uint256 date, address verifier
    );

    event BatchAttestationSubmitted(
        bytes32 indexed batchHash, uint256 indexed missionId, uint256 date, address verifier, uint256 userCount
    );

    event RewardPaid(uint256 indexed missionId, address indexed user, uint256 amount, uint256 date);

    event MissionStatusChanged(uint256 indexed missionId, MissionStatus oldStatus, MissionStatus newStatus);

    event MissionBudgetAdded(
        uint256 indexed missionId, address indexed creator, uint256 additionalBudget, uint256 newTotalBudget
    );

    event MissionEndDateUpdated(
        uint256 indexed missionId, address indexed creator, uint256 oldEndDate, uint256 newEndDate
    );

    // 에러
    error InvalidMission();
    error UnauthorizedVerifier();
    error InvalidAttestation();
    error AlreadyProcessed();
    error InsufficientBudget();
    error MissionNotActive();
    error NotMissionCreator();
    error InvalidSignature();
    error ArrayLengthMismatch();
    error TooManyUsers();

    // 생성자
    constructor(address _defaultVerifier) Ownable(msg.sender) {
        defaultVerifier = _defaultVerifier;
        // 업적 NFT 컨트랙트 배포 및 주소 저장
        AchievementNFT nft = new AchievementNFT("AchievementNFT", "ACHV");
        achievementNFT = address(nft);
        emit AchievementNFTSet(achievementNFT);
    }

    /**
     * @dev 새로운 미션을 제안합니다 (오너 승인 필요)
     */
    function createMissionProposal(
        string memory _name,
        string memory _description,
        address _underlyingToken,
        uint256 _totalBudget,
        uint256 _startDate,
        uint256 _endDate,
        address[] memory _authorizedVerifiers,
        address[] memory _authorizedMerchants,
        bool _transferable
    ) external returns (uint256 proposalId) {
        require(_totalBudget > 0, "Invalid budget");
        require(_startDate < _endDate, "Invalid dates");
        require(_authorizedVerifiers.length > 0, "No verifiers");

        proposalId = nextProposalId++;
        MissionProposal storage proposal = proposedMissions[proposalId];
        proposal.name = _name;
        proposal.description = _description;
        proposal.creator = msg.sender;
        proposal.underlyingToken = _underlyingToken;
        proposal.totalBudget = _totalBudget;
        proposal.startDate = _startDate;
        proposal.endDate = _endDate;
        proposal.authorizedVerifiers = _authorizedVerifiers;
        proposal.authorizedMerchants = _authorizedMerchants;
        proposal.transferable = _transferable;
        proposal.approved = false;

        emit MissionProposed(proposalId, _name, msg.sender, _underlyingToken, _totalBudget);
    }

    /**
     * @dev 오너가 미션 제안을 승인하여 실제 미션을 생성합니다
     */
    function approveMission(uint256 proposalId) external onlyOwner nonReentrant returns (uint256 missionId) {
        MissionProposal storage proposal = proposedMissions[proposalId];
        require(!proposal.approved, "Already approved");
        require(proposal.totalBudget > 0, "Invalid proposal");

        missionId = nextMissionId++;

        // MissionToken 배포
        string memory tokenName = string(abi.encodePacked("Mission-", proposal.name));
        string memory tokenSymbol = string(abi.encodePacked("M", proposal.name));

        MissionToken rewardToken = new MissionToken(
            tokenName, tokenSymbol, proposal.underlyingToken, proposal.transferable, proposal.authorizedMerchants
        );

        // 미션 정보 저장
        Mission storage mission = missions[missionId];
        mission.name = proposal.name;
        mission.description = proposal.description;
        mission.creator = proposal.creator;
        mission.rewardToken = address(rewardToken);
        mission.totalBudget = proposal.totalBudget;
        mission.spentBudget = 0;
        mission.startDate = proposal.startDate;
        mission.endDate = proposal.endDate;
        mission.status = MissionStatus.Active;
        mission.authorizedVerifiers = proposal.authorizedVerifiers;

        // 예산을 기본 토큰으로 예치하고 MissionToken mint
        IERC20(proposal.underlyingToken).transferFrom(proposal.creator, address(this), proposal.totalBudget);
        IERC20(proposal.underlyingToken).approve(address(rewardToken), proposal.totalBudget);
        rewardToken.mint(proposal.totalBudget);

        proposal.approved = true;
        emit MissionCreated(missionId, proposal.name, proposal.creator, address(rewardToken), proposal.totalBudget);
    }

    /**
     * @dev 검증서를 제출하여 보상을 청구합니다 (단일 사용자)
     */
    function submitAttestation(
        address user,
        uint256 missionId,
        uint256 date,
        bytes32 dataHash,
        uint256 reward,
        address verifier,
        bytes memory signature
    ) external nonReentrant {
        // 기본 검증
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();
        if (mission.status != MissionStatus.Active) revert MissionNotActive();

        // 검증기관 승인 확인
        bool isAuthorizedVerifier = false;
        for (uint256 i = 0; i < mission.authorizedVerifiers.length; i++) {
            if (mission.authorizedVerifiers[i] == verifier) {
                isAuthorizedVerifier = true;
                break;
            }
        }
        if (!isAuthorizedVerifier) revert UnauthorizedVerifier();

        // 서명 검증
        bytes32 messageHash = keccak256(abi.encodePacked(user, missionId, date, dataHash, reward));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, signature);
        if (recoveredSigner != verifier) revert InvalidSignature();

        // 검증서 해시 생성 및 중복 처리 확인
        bytes32 attestationHash = keccak256(abi.encode(user, missionId, date, dataHash));
        if (processedAttestations[attestationHash]) revert AlreadyProcessed();

        // 날짜 검증
        uint256 currentDate = getCurrentDate();
        require(date <= currentDate, "Future date not allowed");
        require(currentDate - date <= maxAttestationAge, "Too old attestation");

        // 사용자 참여 정보
        UserParticipation storage participation = userParticipations[missionId][user];

        // 예산 확인
        if (mission.spentBudget + reward > mission.totalBudget) revert InsufficientBudget();

        // 0보상은 처리하지 않음
        if (reward == 0) return;

        // 검증서 처리 완료 표시
        processedAttestations[attestationHash] = true;

        // 보상 지급
        mission.spentBudget += reward;
        participation.totalRewardsEarned += reward;

        // 미션 수행 횟수 증가 및 이벤트
        _userMissionCompletions[missionId][user] += 1;
        emit MissionCompleted(user, missionId, _userMissionCompletions[missionId][user], date);

        // MissionToken 전송
        MissionToken(mission.rewardToken).transfer(user, reward);

        emit AttestationSubmitted(attestationHash, user, missionId, date, verifier);
        emit RewardPaid(missionId, user, reward, date);
    }

    /**
     * @dev 배치 검증서를 제출하여 여러 사용자에게 보상을 청구합니다
     */
    function submitBatchAttestation(BatchAttestation memory batchAttestation) external nonReentrant {
        // 기본 검증
        if (batchAttestation.users.length != batchAttestation.dataHashes.length) revert ArrayLengthMismatch();
        if (batchAttestation.users.length != batchAttestation.rewards.length) revert ArrayLengthMismatch();
        if (batchAttestation.users.length == 0 || batchAttestation.users.length > 100) revert TooManyUsers(); // 최대 100명

        Mission storage mission = missions[batchAttestation.missionId];
        if (mission.creator == address(0)) revert InvalidMission();
        if (mission.status != MissionStatus.Active) revert MissionNotActive();

        // 검증기관 승인 확인
        bool isAuthorizedVerifier = false;
        for (uint256 i = 0; i < mission.authorizedVerifiers.length; i++) {
            if (mission.authorizedVerifiers[i] == batchAttestation.verifier) {
                isAuthorizedVerifier = true;
                break;
            }
        }
        if (!isAuthorizedVerifier) revert UnauthorizedVerifier();

        // 배치 서명 검증
        bytes32 batchMessageHash = keccak256(
            abi.encode(
                batchAttestation.users,
                batchAttestation.missionId,
                batchAttestation.date,
                batchAttestation.dataHashes,
                batchAttestation.rewards
            )
        );
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(batchMessageHash);
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, batchAttestation.signature);
        if (recoveredSigner != batchAttestation.verifier) revert InvalidSignature();

        // 날짜 검증
        uint256 currentDate = getCurrentDate();
        require(batchAttestation.date <= currentDate, "Future date not allowed");
        require(currentDate - batchAttestation.date <= maxAttestationAge, "Too old attestation");

        // 총 보상 계산 및 예산 확인
        uint256 totalReward = 0;
        for (uint256 i = 0; i < batchAttestation.rewards.length; i++) {
            totalReward += batchAttestation.rewards[i];
        }
        if (mission.spentBudget + totalReward > mission.totalBudget) revert InsufficientBudget();

        // 각 사용자에 대해 처리
        for (uint256 i = 0; i < batchAttestation.users.length; i++) {
            address user = batchAttestation.users[i];
            bytes32 dataHash = batchAttestation.dataHashes[i];
            uint256 reward = batchAttestation.rewards[i];

            // 0보상은 스킵
            if (reward == 0) continue;

            // 개별 검증서 해시 생성 및 중복 처리 확인
            bytes32 attestationHash =
                keccak256(abi.encode(user, batchAttestation.missionId, batchAttestation.date, dataHash));
            if (processedAttestations[attestationHash]) continue; // 이미 처리된 것은 스킵

            // 사용자 참여 정보
            UserParticipation storage participation = userParticipations[batchAttestation.missionId][user];

            // 검증서 처리 완료 표시
            processedAttestations[attestationHash] = true;

            // 보상 지급
            mission.spentBudget += reward;
            participation.totalRewardsEarned += reward;

            // 미션 수행 횟수 증가 및 이벤트
            _userMissionCompletions[batchAttestation.missionId][user] += 1;
            emit MissionCompleted(
                user,
                batchAttestation.missionId,
                _userMissionCompletions[batchAttestation.missionId][user],
                batchAttestation.date
            );

            // MissionToken 전송
            MissionToken(mission.rewardToken).transfer(user, reward);

            emit RewardPaid(batchAttestation.missionId, user, reward, batchAttestation.date);
        }

        bytes32 batchHash = keccak256(abi.encode(batchAttestation));
        emit BatchAttestationSubmitted(
            batchHash,
            batchAttestation.missionId,
            batchAttestation.date,
            batchAttestation.verifier,
            batchAttestation.users.length
        );
    }

    // =============================================================================
    // OWNER ONLY FUNCTIONS (Setter Functions)
    // =============================================================================

    /**
     * @dev 검증서 유효 기간 설정
     */
    function setMaxAttestationAge(uint256 _maxAttestationAge) external onlyOwner {
        maxAttestationAge = _maxAttestationAge;
    }

    /**
     * @dev 기본 검증자 주소 설정
     */
    function setDefaultVerifier(address _defaultVerifier) external onlyOwner {
        defaultVerifier = _defaultVerifier;
    }

    /**
     * @dev 미션의 총 예산 수정 (오너만 가능)
     */
    function setMissionTotalBudget(uint256 missionId, uint256 newTotalBudget) external onlyOwner {
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();
        require(newTotalBudget >= mission.spentBudget, "Budget cannot be less than spent amount");

        mission.totalBudget = newTotalBudget;
    }

    /**
     * @dev 미션의 종료일 수정 (오너만 가능)
     */
    function setMissionEndDate(uint256 missionId, uint256 newEndDate) external onlyOwner {
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();
        require(newEndDate > mission.startDate, "End date must be after start date");

        mission.endDate = newEndDate;
    }

    /**
     * @dev 미션 예산 추가 (미션 생성자 가능)
     */
    function addMissionBudget(uint256 missionId, uint256 additionalBudget) external nonReentrant {
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();
        if (mission.creator != msg.sender) revert NotMissionCreator();
        require(additionalBudget > 0, "Invalid additional budget");

        // 추가 예산을 기본 토큰으로 전송받기
        MissionToken rewardToken = MissionToken(mission.rewardToken);
        address underlyingToken = address(rewardToken.underlyingToken());

        IERC20(underlyingToken).transferFrom(msg.sender, address(this), additionalBudget);
        IERC20(underlyingToken).approve(address(rewardToken), additionalBudget);
        rewardToken.mint(additionalBudget);

        // 총 예산 증가
        mission.totalBudget += additionalBudget;

        emit MissionBudgetAdded(missionId, msg.sender, additionalBudget, mission.totalBudget);
    }

    /**
     * @dev 미션의 종료일 수정 (미션 생성자 가능)
     */
    function updateMissionEndDate(uint256 missionId, uint256 newEndDate) external {
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();
        if (mission.creator != msg.sender) revert NotMissionCreator();
        require(newEndDate > mission.startDate, "End date must be after start date");

        uint256 oldEndDate = mission.endDate;
        mission.endDate = newEndDate;

        emit MissionEndDateUpdated(missionId, msg.sender, oldEndDate, newEndDate);
    }

    /**
     * @dev 긴급 상황 시 미션 상태 강제 변경 (오너만 가능)
     */
    function emergencyChangeMissionStatus(uint256 missionId, MissionStatus newStatus) external onlyOwner {
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();

        MissionStatus oldStatus = mission.status;
        mission.status = newStatus;

        emit MissionStatusChanged(missionId, oldStatus, newStatus);
    }

    /**
     * @dev 긴급 상황 시 검증기관 추가 (오너만 가능)
     */
    function emergencyAddVerifier(uint256 missionId, address verifier) external onlyOwner {
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();

        mission.authorizedVerifiers.push(verifier);
    }

    /**
     * @dev 긴급 상황 시 검증기관 제거 (오너만 가능)
     */
    function emergencyRemoveVerifier(uint256 missionId, address verifier) external onlyOwner {
        Mission storage mission = missions[missionId];
        if (mission.creator == address(0)) revert InvalidMission();

        for (uint256 i = 0; i < mission.authorizedVerifiers.length; i++) {
            if (mission.authorizedVerifiers[i] == verifier) {
                mission.authorizedVerifiers[i] = mission.authorizedVerifiers[mission.authorizedVerifiers.length - 1];
                mission.authorizedVerifiers.pop();
                break;
            }
        }
    }

    /**
     * @dev 미션 상태 변경 (미션 생성자만 가능)
     */
    function changeMissionStatus(uint256 missionId, MissionStatus newStatus) external {
        Mission storage mission = missions[missionId];
        if (mission.creator != msg.sender) revert NotMissionCreator();

        MissionStatus oldStatus = mission.status;
        mission.status = newStatus;

        emit MissionStatusChanged(missionId, oldStatus, newStatus);
    }

    /**
     * @dev 미션에 검증기관 추가
     */
    function addVerifier(uint256 missionId, address verifier) external {
        Mission storage mission = missions[missionId];
        if (mission.creator != msg.sender) revert NotMissionCreator();

        mission.authorizedVerifiers.push(verifier);
    }

    /**
     * @dev 미션에 가맹점 추가
     */
    function addMerchant(uint256 missionId, address merchant) external {
        Mission storage mission = missions[missionId];
        if (mission.creator != msg.sender) revert NotMissionCreator();

        MissionToken(mission.rewardToken).addMerchant(merchant);
    }

    /**
     * @dev 미션에서 가맹점 제거
     */
    function removeMerchant(uint256 missionId, address merchant) external {
        Mission storage mission = missions[missionId];
        if (mission.creator != msg.sender) revert NotMissionCreator();

        MissionToken(mission.rewardToken).removeMerchant(merchant);
    }

    /**
     * @dev 현재 날짜를 YYYYMMDD 형식으로 반환 (간단한 구현)
     */
    function getCurrentDate() public view returns (uint256) {
        // 실제 구현에서는 오라클이나 더 정확한 날짜 계산 필요
        // 여기서는 블록 타임스탬프를 기반으로 간단히 구현
        uint256 timestamp = block.timestamp;
        uint256 day = timestamp / 86400; // 하루 = 86400초

        // 2024년 1월 1일을 기준으로 계산 (간단한 예시)
        uint256 baseDate = 20240101;
        return baseDate + day;
    }

    /**
     * @dev 미션 정보 조회
     */
    function getMission(uint256 missionId) external view returns (Mission memory) {
        return missions[missionId];
    }

    /**
     * @dev 사용자 참여 정보 조회
     */
    function getUserParticipation(uint256 missionId, address user) external view returns (UserParticipation memory) {
        return userParticipations[missionId][user];
    }

    /**
     * @dev 미션의 검증기관 목록 조회
     */
    function getMissionVerifiers(uint256 missionId) external view returns (address[] memory) {
        return missions[missionId].authorizedVerifiers;
    }
}
