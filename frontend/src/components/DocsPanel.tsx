import { Box, IconButton, useColorModeValue } from '@chakra-ui/react';
import { FiX } from 'react-icons/fi';

interface DocsPanelProps {
  isOpen: boolean;
  onClose: () => void;
}

function DocsPanel({ isOpen, onClose }: DocsPanelProps) {
  const bgColor = useColorModeValue('white', 'gray.800');
  const borderColor = useColorModeValue('gray.200', 'gray.700');

  return (
    <Box
      position="fixed"
      top={0}
      right={0}
      bottom={0}
      w={{ base: '100vw', md: '50vw', lg: '45vw' }}
      bg={bgColor}
      borderLeft="1px"
      borderColor={borderColor}
      zIndex={30}
      transform={isOpen ? 'translateX(0)' : 'translateX(100%)'}
      transition="transform 0.3s cubic-bezier(0.4, 0, 0.2, 1)"
      boxShadow={isOpen ? '-4px 0 12px rgba(0,0,0,0.3)' : 'none'}
      display="flex"
      flexDirection="column"
    >
      <Box position="absolute" top={2} right={2} zIndex={31}>
        <IconButton
          aria-label="Close documentation"
          icon={<FiX />}
          onClick={onClose}
          size="sm"
          variant="ghost"
          colorScheme="brand"
        />
      </Box>

      {/* iframe stays mounted so it preserves navigation state */}
      <Box
        as="iframe"
        src="/docs/"
        title="Documentation"
        w="100%"
        h="100%"
        border="none"
        flex={1}
      />
    </Box>
  );
}

export default DocsPanel;
