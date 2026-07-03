// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HermesRitualLLM
/// @notice Bridges a Hermes AI agent to Ritual Chain's native, enshrined LLM
///         precompile (0x0802) for decentralized, TEE-verified on-chain inference.
///
///         Flow: an EOA/agent submits a prompt -> this contract calls the LLM
///         precompile -> the short-running async settlement injects the model
///         response back into the same transaction (fulfilled replay, NO callback)
///         -> the decoded assistant text is stored and emitted on-chain.
///
///         Fees are paid in RITUAL through RitualWallet, not EVM gas. Deposit
///         before requesting inference; the chain escrows a worst-case amount at
///         commitment and refunds the unused remainder after settlement.
///
/// @dev    ABI, addresses and semantics per the ritual-foundation/ritual-dapp-skills
///         reference (skills: ritual-dapp-llm, ritual-dapp-wallet, ritual-dapp-da).
///         Model is pinned to the only current production model, GLM-4.7-FP8.
interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address user) external view returns (uint256);
    function lockUntil(address user) external view returns (uint256);
}

contract HermesRitualLLM {
    // --- Ritual system addresses (Chain ID 1979) ---
    address public constant LLM_PRECOMPILE =
        0x0000000000000000000000000000000000000802;
    IRitualWallet public constant RITUAL_WALLET =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    /// @notice The only model confirmed live in production. Do not change without
    ///         verifying against ModelPricingRegistry / TEEServiceRegistry.
    string public constant MODEL = "zai-org/GLM-4.7-FP8";

    // --- StorageRef tuple for conversation history (DA). Empty = no history. ---
    struct StorageRef {
        string platform; // 'gcs' | 'hf' | 'pinata' | '' (none)
        string path;
        string keyRef;
    }

    // --- Tunable request parameters (owner-managed) ---
    /// @notice Blocks until the async commitment expires. >=60 required; 300 default.
    uint256 public ttl = 300;
    /// @notice Output token budget. GLM-4.7-FP8 is a reasoning model: keep >=4096
    ///         or replies can come back empty with finish_reason "length".
    int256 public maxCompletionTokens = 4096;
    /// @notice Sampling temperature, scaled x1000 (700 = 0.7).
    int256 public temperature = 700;

    // --- Inference records ---
    struct Inference {
        address requester;
        bool completed;
        bool hasError;
        string content; // decoded assistant text ("" on error / undecodable)
        string finishReason;
        string errorMessage;
        bytes completionData; // raw ABI-encoded CompletionData for off-chain decode
    }

    uint256 public inferenceCount;
    mapping(uint256 => Inference) public inferences;

    address public owner;

    event InferenceRequested(
        uint256 indexed id,
        address indexed requester,
        address executor
    );
    event InferenceCompleted(
        uint256 indexed id,
        address indexed requester,
        bool hasError,
        string content,
        string errorMessage
    );
    event FeesDeposited(address indexed from, uint256 amount, uint256 lockDuration);

    error NotOwner();
    error EmptyExecutor();
    error PrecompileCallFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ------------------------------------------------------------------
    // Inference
    // ------------------------------------------------------------------

    /// @notice Submit a plain-text prompt. The prompt is JSON-escaped and wrapped
    ///         as a single OpenAI-style user message, then sent to the LLM precompile.
    /// @param executor A registered TEE executor address with LLM capability
    ///        (from TEEServiceRegistry.getServicesByCapability(1, true)).
    /// @param prompt   Arbitrary user text.
    /// @return id      The inference record id (results are stored under it).
    function ask(address executor, string calldata prompt)
        external
        returns (uint256 id)
    {
        return _infer(executor, _wrapPrompt(prompt));
    }

    /// @notice Submit a fully-formed OpenAI-style messages JSON array. Use this for
    ///         multi-turn context or system prompts; the caller owns JSON validity.
    /// @param executor    A registered TEE executor address (LLM capability).
    /// @param messagesJson JSON array, e.g. [{"role":"user","content":"hi"}].
    function askWithMessages(address executor, string calldata messagesJson)
        external
        returns (uint256 id)
    {
        return _infer(executor, messagesJson);
    }

    function _infer(address executor, string memory messagesJson)
        internal
        returns (uint256 id)
    {
        if (executor == address(0)) revert EmptyExecutor();

        id = inferenceCount++;
        emit InferenceRequested(id, msg.sender, executor);

        // Full 30-field LLM request tuple. Field order/types are load-bearing:
        // a mismatch is rejected at RPC with "-32602 invalid async payload".
        // convoHistory (field 30) is an empty StorageRef => stateless, no history.
        bytes memory input = abi.encode(
            executor, //  1 executor
            new bytes[](0), //  2 encryptedSecrets
            ttl, //  3 ttl
            new bytes[](0), //  4 secretSignatures
            bytes(""), //  5 userPublicKey
            messagesJson, //  6 messagesJson
            MODEL, //  7 model
            int256(0), //  8 frequencyPenalty
            "", //  9 logitBiasJson
            false, // 10 logprobs
            maxCompletionTokens, // 11 maxCompletionTokens
            "", // 12 metadataJson
            "", // 13 modalitiesJson
            uint256(1), // 14 n
            true, // 15 parallelToolCalls
            int256(0), // 16 presencePenalty
            "medium", // 17 reasoningEffort
            bytes(""), // 18 responseFormatData
            int256(-1), // 19 seed (null)
            "auto", // 20 serviceTier
            "", // 21 stopJson
            false, // 22 stream
            temperature, // 23 temperature (x1000)
            bytes(""), // 24 toolChoiceData
            bytes(""), // 25 toolsData
            int256(-1), // 26 topLogprobs (null)
            int256(1000), // 27 topP (1.0 x1000)
            "", // 28 user
            false, // 29 piiEnabled
            StorageRef("", "", "") // 30 convoHistory (empty => no history)
        );

        (bool success, bytes memory result) = LLM_PRECOMPILE.call(input);
        if (!success) revert PrecompileCallFailed();

        // Short-running async envelope: (bytes simmedInput, bytes actualOutput).
        (, bytes memory actualOutput) = abi.decode(result, (bytes, bytes));

        // Response envelope:
        // (bool hasError, bytes completionData, bytes modelMetadata,
        //  string errorMessage, (string,string,string) updatedConvoHistory)
        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(
                actualOutput,
                (bool, bytes, bytes, string, StorageRef)
            );

        string memory content;
        string memory finishReason;
        // Always check hasError before touching completionData. Even on
        // hasError=false the model may return malformed data, so decode defensively.
        if (!hasError && completionData.length > 0) {
            try this.decodeCompletion(completionData) returns (
                string memory c,
                string memory fr
            ) {
                content = c;
                finishReason = fr;
            } catch {
                // leave content/finishReason empty; raw bytes kept for off-chain decode
            }
        }

        inferences[id] = Inference({
            requester: msg.sender,
            completed: true,
            hasError: hasError,
            content: content,
            finishReason: finishReason,
            errorMessage: errorMessage,
            completionData: completionData
        });

        emit InferenceCompleted(id, msg.sender, hasError, content, errorMessage);
    }

    /// @notice Decode the assistant text and finish reason out of the ABI-encoded
    ///         CompletionData. External so callers/`ask` can wrap it in try/catch.
    /// @dev    Layout (from ritual-dapp-llm): CompletionData =
    ///         (string id, string object, uint256 created, string model,
    ///          string systemFingerprint, string serviceTier, uint256 choicesCount,
    ///          bytes[] choicesData, bytes usageData).
    ///         choicesData[i] = (uint256 index, string finishReason, bytes messageData).
    ///         messageData = (string role, string content, string refusal,
    ///          uint256 toolCallsCount, bytes[] toolCallsData).
    function decodeCompletion(bytes calldata completionData)
        external
        pure
        returns (string memory content, string memory finishReason)
    {
        (, , , , , , uint256 choicesCount, bytes[] memory choicesData, ) = abi
            .decode(
                completionData,
                (
                    string,
                    string,
                    uint256,
                    string,
                    string,
                    string,
                    uint256,
                    bytes[],
                    bytes
                )
            );

        if (choicesCount == 0 || choicesData.length == 0) {
            return ("", "");
        }

        (, string memory fr, bytes memory messageData) = abi.decode(
            choicesData[0],
            (uint256, string, bytes)
        );
        (, string memory c, , , ) = abi.decode(
            messageData,
            (string, string, string, uint256, bytes[])
        );
        return (c, fr);
    }

    // ------------------------------------------------------------------
    // RitualWallet fee management
    // ------------------------------------------------------------------

    /// @notice Deposit RITUAL into this contract's RitualWallet balance to cover
    ///         inference fees. Lock is monotonic (only ever extends).
    /// @dev    NOTE ON WHO PAYS: the LLM precompile is short-running async and is
    ///         charged against this contract's own RitualWallet balance (this
    ///         contract is the caller of 0x0802). If instead an EOA/agent calls the
    ///         precompile directly, that EOA must fund its own balance — use
    ///         `depositForAgent`. Budget ~0.31 RITUAL of escrow per in-flight call.
    function depositFees(uint256 lockDuration) external payable {
        RITUAL_WALLET.deposit{value: msg.value}(lockDuration);
        emit FeesDeposited(msg.sender, msg.value, lockDuration);
    }

    /// @notice Deposit RITUAL on behalf of a specific agent/EOA that will call the
    ///         precompile directly (async fee checks are against the tx signer).
    function depositForAgent(address agent, uint256 lockDuration)
        external
        payable
    {
        RITUAL_WALLET.depositFor{value: msg.value}(agent, lockDuration);
        emit FeesDeposited(agent, msg.value, lockDuration);
    }

    /// @notice This contract's RitualWallet fee balance, lock expiry, and lock state.
    function feeBalance()
        external
        view
        returns (uint256 balance, uint256 lockExpiry, bool locked)
    {
        balance = RITUAL_WALLET.balanceOf(address(this));
        lockExpiry = RITUAL_WALLET.lockUntil(address(this));
        locked = block.number < lockExpiry;
    }

    /// @notice Withdraw unlocked RITUAL from this contract's RitualWallet balance.
    function withdrawFees(uint256 amount, address payable to) external onlyOwner {
        RITUAL_WALLET.withdraw(amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setTtl(uint256 newTtl) external onlyOwner {
        require(newTtl >= 60, "ttl too low");
        ttl = newTtl;
    }

    function setMaxCompletionTokens(int256 newMax) external onlyOwner {
        require(newMax >= 4096, "below GLM reasoning floor");
        maxCompletionTokens = newMax;
    }

    function setTemperature(int256 newTemp) external onlyOwner {
        require(newTemp >= 0 && newTemp <= 2000, "temp out of range");
        temperature = newTemp;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        owner = newOwner;
    }

    /// @notice Accept withdrawn RITUAL from RitualWallet.
    receive() external payable {}

    // ------------------------------------------------------------------
    // Prompt -> OpenAI messages JSON (with JSON string escaping)
    // ------------------------------------------------------------------

    /// @notice Preview the messages JSON that `ask` would build for `prompt`.
    ///         Useful for off-chain testing of the escaping logic.
    function previewMessages(string calldata prompt)
        external
        pure
        returns (string memory)
    {
        return _wrapPrompt(prompt);
    }

    function _wrapPrompt(string memory prompt)
        internal
        pure
        returns (string memory)
    {
        return
            string.concat(
                '[{"role":"user","content":"',
                _jsonEscape(prompt),
                '"}]'
            );
    }

    /// @dev Escape a UTF-8 string for embedding inside a JSON string literal.
    ///      Handles the mandatory escapes (`"`, `\`) and control chars < 0x20.
    ///      Multi-byte UTF-8 sequences pass through unchanged (valid in JSON).
    function _jsonEscape(string memory s)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(s);
        // Worst case: each byte expands to 6 chars (\u00XX).
        bytes memory out = new bytes(b.length * 6);
        uint256 j = 0;
        bytes16 hexChars = "0123456789abcdef";

        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"') {
                out[j++] = "\\";
                out[j++] = '"';
            } else if (c == "\\") {
                out[j++] = "\\";
                out[j++] = "\\";
            } else if (c == 0x08) {
                out[j++] = "\\";
                out[j++] = "b";
            } else if (c == 0x09) {
                out[j++] = "\\";
                out[j++] = "t";
            } else if (c == 0x0a) {
                out[j++] = "\\";
                out[j++] = "n";
            } else if (c == 0x0c) {
                out[j++] = "\\";
                out[j++] = "f";
            } else if (c == 0x0d) {
                out[j++] = "\\";
                out[j++] = "r";
            } else if (uint8(c) < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(c) >> 4];
                out[j++] = hexChars[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }

        // Trim to the used length.
        assembly {
            mstore(out, j)
        }
        return string(out);
    }
}
