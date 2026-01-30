import { useState, useCallback } from 'react';
import { Box, IconButton, Tooltip, useColorModeValue } from '@chakra-ui/react';
import { FiBarChart2, FiMap } from 'react-icons/fi';
import MapView from './MapView';
import ChartView from './ChartView';
import type { ComparisonState } from '../types';
import { SCENARIOS } from '../types';

interface ViewPaneProps {
  comparison: ComparisonState;
  /** Label shown in quad mode */
  label?: string;
  /** Whether this pane is in a multi-pane layout */
  compact?: boolean;
}

function ViewPane({ comparison, label, compact = false }: ViewPaneProps) {
  const [isChartView, setIsChartView] = useState(false);
  const borderColor = useColorModeValue('gray.600', 'gray.600');

  const handleToggle = useCallback(() => {
    setIsChartView((prev) => !prev);
  }, []);

  const leftInfo = SCENARIOS.find((s) => s.id === comparison.leftScenario);
  const rightInfo = SCENARIOS.find((s) => s.id === comparison.rightScenario);
  const paneLabel = label || `${leftInfo?.label || ''} vs ${rightInfo?.label || ''}`;

  return (
    <Box
      position="relative"
      w="100%"
      h="100%"
      overflow="hidden"
      border={compact ? '1px' : 'none'}
      borderColor={borderColor}
    >
      {/* Map layer */}
      <Box
        position="absolute"
        top={0}
        left={0}
        right={0}
        bottom={0}
        opacity={isChartView ? 0 : 1}
        transition="opacity 0.5s cubic-bezier(0.4, 0, 0.2, 1)"
        pointerEvents={isChartView ? 'none' : 'auto'}
      >
        <MapView comparison={comparison} />
      </Box>

      {/* Chart layer */}
      <ChartView visible={isChartView} />

      {/* Pane label (shown in quad mode) */}
      {compact && (
        <Box
          position="absolute"
          top={2}
          left={2}
          zIndex={5}
          bg="blackAlpha.700"
          color="white"
          px={3}
          py={1}
          borderRadius="md"
          fontSize="xs"
          fontWeight="600"
          letterSpacing="0.5px"
          backdropFilter="blur(8px)"
          pointerEvents="none"
        >
          {paneLabel}
        </Box>
      )}

      {/* Map/Chart toggle button */}
      <Box position="absolute" bottom={compact ? 2 : 3} right={compact ? 2 : 3} zIndex={5}>
        <Tooltip label={isChartView ? 'Show map' : 'Show chart'} placement="left">
          <IconButton
            aria-label="Toggle map/chart"
            icon={isChartView ? <FiMap /> : <FiBarChart2 />}
            onClick={handleToggle}
            variant="solid"
            bg="blackAlpha.600"
            color="white"
            _hover={{ bg: 'blackAlpha.800' }}
            size={compact ? 'xs' : 'sm'}
            borderRadius="md"
          />
        </Tooltip>
      </Box>
    </Box>
  );
}

export default ViewPane;
