import { useState, useCallback } from 'react';
import { Box, Flex, useDisclosure } from '@chakra-ui/react';
import ContentArea from './components/ContentArea';
import ControlPanel from './components/ControlPanel';
import Header from './components/Header';
import DocsPanel from './components/DocsPanel';
import SetupGuide from './components/SetupGuide';
import { useServerInfo } from './hooks/useApi';
import type { Scenario, ComparisonState } from './types';

type LayoutMode = 'single' | 'quad';

function App() {
  const { isOpen, onToggle } = useDisclosure({ defaultIsOpen: false });
  const { isOpen: isDocsOpen, onToggle: onToggleDocs, onClose: onCloseDocs } = useDisclosure({ defaultIsOpen: false });
  const [layoutMode, setLayoutMode] = useState<LayoutMode>('single');
  const { info } = useServerInfo();

  const handleToggleQuad = useCallback(() => {
    setLayoutMode((prev) => (prev === 'single' ? 'quad' : 'single'));
  }, []);

  const [comparison, setComparison] = useState<ComparisonState>({
    leftScenario: 'past',
    rightScenario: 'present',
    attribute: '',
  });

  const handleLeftChange = useCallback((scenario: Scenario) => {
    setComparison((prev) => ({ ...prev, leftScenario: scenario }));
  }, []);

  const handleRightChange = useCallback((scenario: Scenario) => {
    setComparison((prev) => ({ ...prev, rightScenario: scenario }));
  }, []);

  const handleAttributeChange = useCallback((attribute: string) => {
    setComparison((prev) => ({ ...prev, attribute }));
  }, []);

  // Show setup guide when tiles aren't loaded
  if (info && !info.tiles_loaded) {
    return <SetupGuide info={info} />;
  }

  return (
    <Flex direction="column" h="100vh" overflow="hidden">
      <Header
        onTogglePanel={onToggle}
        isPanelOpen={isOpen}
        onToggleDocs={onToggleDocs}
        isDocsOpen={isDocsOpen}
        onToggleQuad={handleToggleQuad}
        isQuadMode={layoutMode === 'quad'}
      />

      <Flex flex={1} overflow="hidden" position="relative">
        {/* Main content area - shrinks when panel opens */}
        <Box
          flex={1}
          transition="margin-right 0.3s cubic-bezier(0.4, 0, 0.2, 1)"
          mr={isOpen ? { base: 0, md: '400px', lg: '440px' } : 0}
          position="relative"
        >
          <ContentArea mode={layoutMode} comparison={comparison} />
        </Box>

        {/* Slide-out control panel */}
        <ControlPanel
          isOpen={isOpen}
          comparison={comparison}
          onLeftChange={handleLeftChange}
          onRightChange={handleRightChange}
          onAttributeChange={handleAttributeChange}
        />
      </Flex>

      {/* Docs panel - always mounted to preserve iframe navigation state */}
      <DocsPanel isOpen={isDocsOpen} onClose={onCloseDocs} />
    </Flex>
  );
}

export default App;
