# 🛡️ Contract Verification NFTs

A Clarity smart contract system that issues NFT certificates for verified smart contracts, providing a decentralized and transparent way to track contract audits and verifications.

## 🌟 Features

- 🎫 **NFT Certificates**: Each verified contract receives a unique NFT certificate
- 🔐 **Multi-level Verification**: Support for Basic, Standard, Premium, and Enterprise verification levels
- ⏰ **Time-based Expiry**: Verifications expire after specified block heights
- 👥 **Verifier Registry**: Authorized verifiers with reputation scoring system
- 💰 **Fee Structure**: Configurable fees based on verification level and duration
- 📊 **Batch Processing**: Verify multiple contracts in a single transaction
- 🔄 **Extensions**: Extend verification periods by paying additional fees

## 📋 Verification Levels

| Level | Min Duration | Base Fee | Required Reputation |
|-------|-------------|----------|-------------------|
| Basic | 144 blocks (~1 day) | 0.5 STX | 0 |
| Standard | 1,008 blocks (~1 week) | 2 STX | 50 |
| Premium | 4,032 blocks (~1 month) | 10 STX | 100 |
| Enterprise | 8,064 blocks (~2 months) | 50 STX | 200 |

## 🚀 Getting Started

### Prerequisites

- [Clarinet](https://github.com/hirosystems/clarinet)
- [Stacks CLI](https://docs.stacks.co/docs/cli)

### Installation

1. Clone the repository
2. Navigate to the project directory
3. Run Clarinet check to verify the contract:

```bash
clarinet check
```

### 🔧 Core Functions

#### For Contract Owners

**Register as a Verifier** (Owner only)
```clarity
(contract-call? .contract-verification-nfts register-verifier 'SP1ABC...)
```

**Set Verification Level** (Owner only)
```clarity
(contract-call? .contract-verification-nfts set-verification-level 
  "custom" u2016 u5000000 u75)
```

#### For Verifiers

**Mint Verification Certificate**
```clarity
(contract-call? .contract-verification-nfts mint-verification-certificate
  'SP2CONTRACT... "standard" u1008 (some u"https://metadata-uri.com"))
```

**Batch Verify Contracts**
```clarity
(contract-call? .contract-verification-nfts batch-verify-contracts
  (list {address: 'SP1ABC..., level: "basic", duration: u144}
        {address: 'SP2DEF..., level: "standard", duration: u1008}))
```

**Revoke Verification**
```clarity
(contract-call? .contract-verification-nfts revoke-verification u1)
```

#### For NFT Holders

**Transfer Certificate**
```clarity
(contract-call? .contract-verification-nfts transfer u1 tx-sender 'SP1RECIPIENT...)
```

**Extend Verification**
```clarity
(contract-call? .contract-verification-nfts extend-verification u1 u504)
```

**Burn Certificate**
```clarity
(contract-call? .contract-verification-nfts burn u1)
```

### 📖 Read Functions

**Check if Contract is Verified**
```clarity
(contract-call? .contract-verification-nfts is-contract-verified 'SP1CONTRACT...)
```

**Get Verification Status**
```clarity
(contract-call? .contract-verification-nfts get-verification-status 'SP1CONTRACT...)
```

**Get Token Metadata**
```clarity
(contract-call? .contract-verification-nfts get-token-metadata u1)
```

**Get Verifier Information**
```clarity
(contract-call? .contract-verification-nfts get-verifier-info 'SP1VERIFIER...)
```

## 🏗️ Contract Structure

### Data Maps

- **token-metadata**: Stores NFT certificate details
- **contract-verifications**: Links contracts to their verification status
- **verifier-registry**: Manages authorized verifiers and their reputation
- **verification-levels**: Configurable verification tier settings

### Key Constants

- **contract-owner**: The deployer of the contract
- **Error codes**: Standardized error responses (u100-u108)
- **Default verification levels**: Pre-configured Basic through Enterprise tiers

## 🔍 Usage Examples

### Verify a DeFi Contract

1. Register as a verifier (if authorized)
2. Mint a verification certificate for the DeFi contract
3. Contract receives an NFT proving it has been audited
4. Users can check verification status before interacting

### Extend an Expiring Verification

1. Check when your verification expires
2. Call extend-verification with additional blocks
3. Pay the calculated extension fee
4. Verification period is extended

### Batch Audit Multiple Contracts

1. Prepare a list of contracts with their verification levels
2. Call batch-verify-contracts
3. Multiple NFT certificates are minted in one transaction

## ⚡ Testing

Run the test suite:

```bash
npm install
npm test
```


## 📄 License

This project is open source and available under the MIT License.

## 🎯 Roadmap

- [ ] Integration with popular audit firms
- [ ] Automated verification renewal alerts  
- [ ] Multi-signature verification requirements
- [ ] Integration with governance tokens
- [ ] Cross-chain verification support

---

Built with ❤️ on Stacks blockchain
