pragma solidity >=0.4.21 <0.6.0;

import "./Blake2b.sol";

/**
 * @author Wanseob Lim <email@wanseob.com>
 * @title Merkle Mountain Range solidity library
 *
 * @dev The index of this MMR implementation starts from 1 not 0.
 *      And it uses Blake2bHash for its hash function instead of blake2b
 */
library MMR {
    using Blake2b for Blake2b.Instance;

    struct Tree {
        bytes32 root;
        uint256 size;
        uint256 width;
        mapping(uint256 => bytes32) hashes;
        mapping(bytes32 => bytes) data;
    }

    function bytesToBytes32(bytes memory b, uint256 offset)
        private
        pure
        returns (bytes32)
    {
        bytes32 out;

        for (uint256 i = 0; i < 32; i++) {
            out |= bytes32(b[offset + i] & 0xFF) >> (i * 8);
        }
        return out;
    }


    function bytes32Concat(bytes32 b1, bytes32 b2) public pure returns (bytes memory)
    {
        bytes memory result = new bytes(64);
        assembly {
            mstore(add(result, 32), b1)
            mstore(add(result, 64), b2)
        }
        return result;
    }

    function Blake2bHash(bytes memory input) view public returns (bytes32) {
      Blake2b.Instance memory instance = Blake2b.init(hex"", 32);
      return bytesToBytes32(instance.finalize(input), 0);
    }

    /**
     * @dev This only stores the hashed value of the leaf.
     *      If you need to retrieve the detail data later, use a map to store them.
     */
    function append(Tree storage tree, bytes memory data, bytes32 leafHash) public {
        // Hash the leaf node first
        bytes32 dataHash = Blake2bHash(data);
        if(Blake2bHash(tree.data[dataHash]) != dataHash) {
            tree.data[dataHash] = data;
        }
        bytes32 leaf = leafHash;
        // Put the hashed leaf to the map
        tree.hashes[tree.size + 1] = leaf;
        tree.width += 1;
        // Find peaks for the enlarged tree
        uint256[] memory peakIndexes = getPeakIndexes(tree.width);
        // The right most peak's value is the new size of the updated tree
        tree.size = getSize(tree.width);
        // Starting from the left-most peak, get all peak hashes using _getOrCreateNode() function.
        bytes32[] memory peaks = new bytes32[](peakIndexes.length);
        for (uint i = 0; i < peakIndexes.length; i++) {
            peaks[i] = _getOrCreateNode(tree, peakIndexes[i]);
        }
        // Create the root hash and update the tree
        tree.root = peakBagging(tree.width, peaks);
    }

    function getPeaks(Tree storage tree) public view returns (bytes32[] memory peaks) {
        // Find peaks for the enlarged tree
        uint256[] memory peakNodeIndexes = getPeakIndexes(tree.width);
        // Starting from the left-most peak, get all peak hashes using _getOrCreateNode() function.
        peaks = new bytes32[](peakNodeIndexes.length);
        for (uint i = 0; i < peakNodeIndexes.length; i++) {
            peaks[i] = tree.hashes[peakNodeIndexes[i]];
        }
        return peaks;
    }

    function getLeafIndex(uint width) public pure returns (uint) {
        if(width % 2 == 1) {
            return getSize(width);
        } else {
            return getSize(width - 1) + 1;
        }
    }

    function getSize(uint width) public pure returns (uint256) {
        return (width << 1) - numOfPeaks(width);
    }

    /**
     * @dev It returns the root value of the tree
     */
    function getRoot(Tree storage tree) public view returns (bytes32) {
        return tree.root;
    }

    /**
     * @dev It returns the size of the tree
     */
    function getSize(Tree storage tree) public view returns (uint256) {
        return tree.size;
    }

    /**
     * @dev It returns the hash value of a node for the given position. Note that the index starts from 1
     */
    function getNode(Tree storage tree, uint256 index) public view returns (bytes32) {
        return tree.hashes[index];
    }

    /**
     * @dev It returns a merkle proof for a leaf. Note that the index starts from 1
     */
    function getMerkleProof(Tree storage tree, uint256 index) public view returns (
        bytes32 root,
        uint256 width,
        bytes32[] memory peakBagging,
        bytes32[] memory siblings
    ){
        require(index < tree.size, "Out of range");
        require(isLeaf(index), "Not a leaf");

        root = tree.root;
        width = tree.width;
        // Find all peaks for bagging
        uint256[] memory peaks = getPeakIndexes(tree.width);

        peakBagging = new bytes32[](peaks.length);
        uint256 cursor;
        for (uint i = 0; i < peaks.length; i++) {
            // Collect the hash of all peaks
            peakBagging[i] = tree.hashes[peaks[i]];
            // Find the peak which includes the target index
            if (peaks[i] >= index && cursor == 0) {
                cursor = peaks[i];
            }
        }
        uint256 left;
        uint256 right;

        // Get hashes of the siblings in the mountain which the index belongs to.
        // It moves the cursor from the summit of the mountain down to the target index
        uint8 height = heightAt(cursor);
        siblings = new bytes32[](height - 1);
        while (cursor != index) {
            height--;
            (left, right) = getChildren(cursor);
            // Move the cursor down to the left side or right side
            cursor = index <= left ? left : right;
            // Remaining node is the sibling
            siblings[height - 1] = tree.hashes[index <= left ? right : left];
        }
    }

    function rollUp(
        bytes32 root,
        uint256 width,
        bytes32[] memory peaks,
        bytes32[] memory itemHashes
    ) public returns (bytes32 newRoot) {
        // Check the root equals the peak bagging hash
        require(root == peakBagging(width, peaks), "Invalid root hash from the peaks");
        uint tmpWidth = width;
        bytes32[255] memory tmpPeakMap = peaksToPeakMap(width, peaks);
        for (uint i = 0; i < itemHashes.length; i++) {
            tmpPeakMap = peakUpdate(tmpWidth, tmpPeakMap, itemHashes[i]);
            tmpWidth++;
        }
        return peakBagging(tmpWidth, peakMapToPeaks(tmpWidth, tmpPeakMap));
    }

    function peakBagging(uint256 width, bytes32[] memory peaks) view public returns (bytes32) {
        uint size = getSize(width);
        require(numOfPeaks(width) == peaks.length, "Received invalid number of peaks");

        bytes32 mergeHash = peaks[0];
        for(uint i = peaks.length-1; i >= 1; i = i - 1) {
            bytes32 r;
            if(i == peaks.length-1) {
                r = peaks[i];
            } else {
                r = mergeHash;
            }
            bytes32 l = peaks[i-1];
            mergeHash = hashBranch(0, r, l);
        }

        return mergeHash;
    }

    function peaksToPeakMap(uint width, bytes32[] memory peaks) public pure returns (bytes32[255] memory peakMap) {
        uint bitIndex;
        uint peakRef;
        uint count = peaks.length;
        for(uint height = 1; height <= 255; height++) {
            // Index starts from the right most bit
            bitIndex = 255 - height;
            peakRef = 1 << (height - 1);
            if((width & peakRef) != 0) {
                peakMap[bitIndex] = peaks[--count];
            } else {
                peakMap[bitIndex] = bytes32(0);
            }
        }
        require(count == 0, "Invalid number of peaks");
    }

    function peakMapToPeaks(uint width, bytes32[255] memory peakMap) public pure returns (bytes32[] memory peaks) {
        uint arrLength = numOfPeaks(width);
        peaks = new bytes32[](arrLength);
        uint count = 0;
        for(uint i = 0; i < 255; i++) {
            if(peakMap[i] != bytes32(0)) {
                peaks[count++] = peakMap[i];
            }
        }
        require(count == arrLength, "Invalid number of peaks");
    }

    function peakUpdate(
        uint width,
        bytes32[255] memory prevPeakMap,
        bytes32 itemHash
    ) public returns (
        bytes32[255] memory nextPeakMap
    ) {
        uint newWidth = width + 1;
        uint cursorIndex = getLeafIndex(newWidth);
        bytes32 cursorNode = hashLeaf(cursorIndex, itemHash);
        uint bitIndex;
        uint peakRef;
        bool prevPeakExist;
        bool nextPeakExist;
        bool obtained;

        for(uint height = 1; height <= 255; height++) {
            // Index starts from the right most bit
            bitIndex = 255 - height;
            if(obtained) {
                nextPeakMap[bitIndex] = prevPeakMap[bitIndex];
            } else {
                peakRef = 1 << (height - 1);
                prevPeakExist = (width & peakRef) != 0;
                nextPeakExist = (newWidth & peakRef) != 0;

                // Get new cursor node with hashing the peak and the current cursor
                cursorIndex++;
                if(prevPeakExist) {
                    cursorNode = hashBranch(cursorIndex, prevPeakMap[bitIndex], cursorNode);
                }
                // If new peak exists for the bit index
                if(nextPeakExist) {
                    // If prev peak exists for the bit index
                    if(prevPeakExist) {
                        nextPeakMap[bitIndex] = prevPeakMap[bitIndex];
                    } else {
                        nextPeakMap[bitIndex] = cursorNode;
                    }
                    obtained = true;
                } else {
                    nextPeakMap[bitIndex] = bytes32(0);
                }
            }
        }
    }

    /** Pure functions */

    /**
     * @dev It returns true when the given params verifies that the given value exists in the tree or reverts the transaction.
     */
    function inclusionProof(
        bytes32 root,
        uint256 width,
        uint256 index,
        bytes memory value,
        bytes32 valueHash,
        bytes32[] memory peaks,
        bytes32[] memory siblings
    ) view public returns (bool) {
        uint size = getSize(width);
        require(size >= index, "Index is out of range");
        // Check the root equals the peak bagging hash
        require(root == peakBagging(width, peaks), "Invalid root hash from the peaks");

        // Find the mountain where the target index belongs to
        uint256 cursor;
        bytes32 targetPeak;
        uint256[] memory peakIndexes = getPeakIndexes(width);
        for (uint i = 0; i < peakIndexes.length; i++) {
            if (peakIndexes[i] >= index) {
                targetPeak = peaks[i];
                cursor = peakIndexes[i];
                break;
            }
        }
        require(targetPeak != bytes32(0), "Target is not found");

        // Find the path climbing down
        uint256[] memory path = new uint256[](siblings.length + 1);
        uint256 left;
        uint256 right;
        uint8 height = uint8(siblings.length) + 1;
        while (height > 0) {
            // Record the current cursor and climb down
            path[--height] = cursor;
            if (cursor == index) {
                // On the leaf node. Stop climbing down
                break;
            } else {
                // On the parent node. Go left or right
                (left, right) = getChildren(cursor);
                cursor = index > left ? right : left;
                continue;
            }
        }

        // Calculate the summit hash climbing up again
        bytes32 node;
        while (height < path.length) {
            // Move cursor
            cursor = path[height];
            if (height == 0) {
                // cursor is on the leaf
                // node = hashLeaf(cursor, Blake2bHash(value));
                node = valueHash;
            } else if (cursor - 1 == path[height - 1]) {
                // cursor is on a parent and a sibling is on the left
                node = hashBranch(cursor, siblings[height - 1], node);
            } else {
                // cursor is on a parent and a sibling is on the right
                node = hashBranch(cursor, node, siblings[height - 1]);
            }
            // Climb up
            height++;
        }

        // Computed hash value of the summit should equal to the target peak hash
        require(node == targetPeak, "Hashed peak is invalid");
        return true;
    }

    /**
     * @dev It returns the hash a parent node with hash(M | Left child | Right child)
     *      M is the index of the node
     */
    function hashBranch(uint256 index, bytes32 left, bytes32 right) view public returns (bytes32) {
        // return Blake2bHash(abi.encodePacked(index, left, right));
        return Blake2bHash(bytes32Concat(left, right));
    }

    /**
     * @dev it returns the hash of a leaf node with hash(M | DATA )
     *      M is the index of the node
     */
    function hashLeaf(uint256 index, bytes32 dataHash) view public returns (bytes32) {
        return Blake2bHash(abi.encodePacked(index, dataHash));
    }

    /**
     * @dev It returns the height of the highest peak
     */
    function mountainHeight(uint256 size) public pure returns (uint8) {
        uint8 height = 1;
        while (uint256(1) << height <= size + height) {
            height++;
        }
        return height - 1;
    }

    /**
     * @dev It returns the height of the index
     */
    function heightAt(uint256 index) public pure returns (uint8 height) {
        uint256 reducedIndex = index;
        uint256 peakIndex;
        // If an index has a left mountain subtract the mountain
        while (reducedIndex > peakIndex) {
            reducedIndex -= (uint256(1) << height) - 1;
            height = mountainHeight(reducedIndex);
            peakIndex = (uint256(1) << height) - 1;
        }
        // Index is on the right slope
        height = height - uint8((peakIndex - reducedIndex));
    }

    /**
     * @dev It returns whether the index is the leaf node or not
     */
    function isLeaf(uint256 index) public pure returns (bool) {
        return heightAt(index) == 1;
    }

    /**
     * @dev It returns the children when it is a parent node
     */
    function getChildren(uint256 index) public pure returns (uint256 left, uint256 right) {
        left = 0;
        right = 0;
        left = index - (uint256(1) << (heightAt(index) - 1));
        right = index - 1;
        require(left != right, "Not a parent");
        return (left, right);
    }

    /**
     * @dev It returns all peaks of the smallest merkle mountain range tree which includes
     *      the given index(size)
     */
    function getPeakIndexes(uint256 width) public pure returns (uint256[] memory peakIndexes) {
        peakIndexes = new uint256[](numOfPeaks(width));
        uint count;
        uint size;
        for(uint i = 255; i > 0; i--) {
            if(width & (1 << (i - 1)) != 0) {
                // peak exists
                size = size + (1 << i) - 1;
                peakIndexes[count++] = size;
            }
        }
        require(count == peakIndexes.length, "Invalid bit calculation");
    }

    function numOfPeaks(uint256 width) public pure returns (uint num) {
        uint256 bits = width;
        while(bits > 0) {
            if(bits % 2 == 1) num++;
            bits = bits >> 1;
        }
        return num;
    }

    /**
     * @dev It returns the hash value of the node for the index.
     *      If the hash already exists it simply returns the stored value. On the other hand,
     *      it computes hashes recursively downward.
     *      Only appending an item calls this function
     */
    function _getOrCreateNode(Tree storage tree, uint256 index) private returns (bytes32) {
        require(index <= tree.size, "Out of range");
        if (tree.hashes[index] == bytes32(0)) {
            (uint256 leftIndex, uint256 rightIndex) = getChildren(index);
            bytes32 leftHash = _getOrCreateNode(tree, leftIndex);
            bytes32 rightHash = _getOrCreateNode(tree, rightIndex);
            tree.hashes[index] = hashBranch(index, leftHash, rightHash);
        }
        return tree.hashes[index];
    }
}